#!/bin/bash

###############################################################################
#                                                                             #
#                    CNIS Audit script                                        #
#                                                                             #
#  Description : Collects CCD audit outputs                                   #  
#  Author      : saanvi                                                       #
#  Created     : June, 2026                                                   #
#                                                                             #
###############################################################################

API_ENDPOINT="http://localhost:11434/v1/chat/completions"
AUTH_HEADER="Authorization: Bearer local-bypass" 
MODEL_NAME="phi3"
AI_MODE="Local Engine"

# execution flag?
RUN_CCD=false

function usage() {
    echo "USAGE: $0 [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  --ccd_audit                  Run CCD Audit"
    echo "  --cloud                      Use Groq API instead instead of local Ollama"
    echo "  -h, --help                   Displaying this message!"
    exit 0
}



while [[ "$#" -gt 0 ]]; do 
  case $1 in 
    --ccd_audit)
      RUN_CCD=true
      ;;

    --cloud)
      API_ENDPOINT="https://api.groq.com/openai/v1/chat/completions"
      AUTH_HEADER="Authorization: Bearer $GROQ_API_KEY"
      MODEL_NAME="llama-3.3-70b-versatile"
      AI_MODE="Cloud Engine (Groq)"
      ;;
    -h|--help)
      usage 
      ;;
    *) 
      echo "unknown parameter passed: $1"
      usage 
      ;;
   esac 
   shift # will shift the queue one by one, so then the loop looks at the new $1 which would be cloud if it was passed in as the second argument 
done 

echo "The target Diagnostics Brain: ${AI_MODE} [Model: ${MODEL_NAME}]"
echo "=============================================================="


function ccd_audit() {
 
    echo "============================="
    echo "STARTING SEARCH FOR ISSUES..." 
    echo "=============================" 

    set -e
    local NAMESPACE="default"
    echo "fetching Kubernetes events from namespace: ${NAMESPACE}..."

    RAW_EVENTS_JSON=$(kubectl get events -n "${NAMESPACE}" -o json)
    local EVENTS_IN_PAYLOAD=$(echo "${RAW_EVENTS_JSON}" | jq '.items | length')

    if [ "${EVENTS_IN_PAYLOAD:-0}" -eq 0 ]; then
      echo "No events that have errors are found, infrastructure is reported as healthy!"
      exit 0
    fi

    echo "Found ${EVENTS_IN_PAYLOAD} events, now parsing important data..."
    echo "======================================================"

    echo "${RAW_EVENTS_JSON}" | jq -c '.items | map(select(.type == "Warning")) | map({event_namespace: .metadata.namespace, reason: .reason, labels: .type, kind: .involvedObject.kind, name: .involvedObject.name, message: .message})' > output_for_llm.json

  _ask_llm() {

    local CLUSTER_STATE=$(< output_for_llm.json)
    local API_PAYLOAD=$(jq -n \
      --arg model_id "$MODEL_NAME" \
      --arg text_prompt "You are an autonomous Kubernetes Site Reliability Engineering agent.
            Your goal is to triage cluster warnings and determine the next logical diagnostic step.
            Analyze the provided JSON array of Kubernetes events. Identify the most critical application failure (prioritize user workloads over background daemon sets). Do not attempt to solve the issue yet.
            Instead, determine the exact kubectl command needed to gather more specific evidence about this failure.
            CRITICAL SRE CONSTRAINT: You are strictly forbidden from suggesting interactive commands 
            that open text editors, require human input, or stream indefinitely (e.g., kubectl edit, kubectl exec -it, kubectl logs -f). 
            You must ONLY suggest imperative, non-interactive commands that execute instantly and return to standard output
            (e.g., kubectl set image, kubectl patch, kubectl logs --tail=50).
            Respond ONLY with a valid JSON object matching this exact schema, with no additional markdown or conversational text:
            { \"target_resource\": \"name\", \"namespace\": \"default\", \"problem\": \"The error message describing the cluster issue\", \"recommended_command\": \"kubectl ...\", \"reasoning\": \"brief explanation\" }" \
      --argjson cluster_data "$CLUSTER_STATE" \
        '{
        "model": $model_id,
        "response_format": { "type": "json_object" },
        "messages": [
          {
            "role": "system",
            "content": $text_prompt
          },
          {
            "role": "user",
            "content": ($cluster_data | tojson)
          }
        ]
      }'
    )

  
   HTTP_STATUS=$(curl -X POST -s -o api_response.json -w "%{http_code}" "$API_ENDPOINT" \
      -H "$AUTH_HEADER" \
      -H 'Content-Type: application/json' \
      -d "$API_PAYLOAD" 
      )
  

   if [ "$HTTP_STATUS" -ne 200 ]; then
    echo "API Error (HTTP Status $HTTP_STATUS):" >&2 # redirects the stdout to the stderr stream
    cat api_response.json >&2
    
    exit 1
   else 
    LLM_RESPONSE=$(jq -r '.choices[0].message.content' api_response.json)
   fi
 }
  
    echo "LLM running to give you the right command to keep debugging..."
    echo "=============================================================="

  _human_in_the_loop() {
    # use saved output, RECOMMENDED_CMD
    # want the actual problem statement visible to user, have the LLM strictly respond with the problem and recommended command
    
    echo "Here is the problem message:" 
    echo "$LLM_RESPONSE" | jq -r '.problem'
    RECOMMENDED_CMD=$(echo "$LLM_RESPONSE" | jq -r '.recommended_command')
    echo "Here is the recommended command to run: ${RECOMMENDED_CMD}"
    echo "Why:" 
    echo "$LLM_RESPONSE" | jq -r '.reasoning'

    echo -n "Would you like to run ${RECOMMENDED_CMD}? Answer y/n. "
    read answer 
    if [ "${answer}" == "y" ]
    then 
      echo "Running: ${RECOMMENDED_CMD}"
      set +e
      COMMAND_OUTPUT=$(gtimeout 30 eval "$RECOMMENDED_CMD" 2>&1) # force stderr and stdout to the same location
      set -e
      echo $COMMAND_OUTPUT
    fi 

    if [ "${answer}" == "n" ]
    then 
      echo "Ok bye!"
      exit 1 
    fi 
    
  }

  _ask_llm_again() {
   local SECOND_API_PAYLOAD=$(jq -n \
      --arg model_id "$MODEL_NAME" \
      --arg text_prompt "Analyze this terminal output. If the output shows the issue is resolved, output a final success summary. 
            If the output shows a new error or further details, output the next logical command to continue debugging.
            CRITICAL SRE CONSTRAINT: You are strictly forbidden from suggesting interactive commands 
            that open text editors, require human input, or stream indefinitely (e.g., kubectl edit, kubectl exec -it, kubectl logs -f). 
            You must ONLY suggest imperative, non-interactive commands that execute instantly and return to standard output
            (e.g., kubectl set image, kubectl patch, kubectl logs --tail=50).
            Respond ONLY with a valid JSON object matching this exact schema:
            { \"status\": \"resolved_or_unresolved\", \"problem\": \"summary of the current state\", \"recommended_command\": \"kubectl ... or null if resolved\", \"reasoning\": \"why\" }" \
      --arg second_data "$COMMAND_OUTPUT" \
        '{
        "model": $model_id,
        "response_format": { "type": "json_object" },
        "messages": [
          {
            "role": "system",
            "content": $text_prompt
          },
          {
            "role": "user",
            "content": $second_data
          }
        ]
      }'
    )

    
   HTTP_STATUS_2=$(curl -X POST -s -o api_response2.json -w "%{http_code}" "$API_ENDPOINT" \
      -H "$AUTH_HEADER" \
      -H 'Content-Type: application/json' \
      -d "$SECOND_API_PAYLOAD" 
      )
  

   if [ "$HTTP_STATUS_2" -ne 200 ]; then
    echo "API Error (HTTP Status $HTTP_STATUS_2):" >&2 # redirects the stdout to the stderr stream
    cat api_response2.json >&2
    
    exit 1
   else 
    LLM_RESPONSE_2=$(jq -r '.choices[0].message.content' api_response2.json)
   fi
    
 }
  
    echo "LLM running AGAIN to re-affirm the process...giving you summary here..."
    echo "=============================================================="

  _ask_llm
  CURRENT_STATUS="unresolved"
  LOOP_COUNT=0
  MAX_LOOPS=5 


  while [[ "$CURRENT_STATUS" != "resolved" && $LOOP_COUNT -lt $MAX_LOOPS ]]; do 
    _human_in_the_loop
    _ask_llm_again
    CURRENT_STATUS=$(echo "$LLM_RESPONSE_2" | jq -r '.status')

    LLM_RESPONSE="$LLM_RESPONSE_2" # overwrite so next loop iteration has new command 
    FINAL_SUMMARY=$(echo "$LLM_RESPONSE_2" | jq -r '.problem') # updating a summary, still debugging this 
    # get all of them in one, not just the last command or reasoning

    ((LOOP_COUNT++))
    echo "$FINAL_SUMMARY" > log_of_agent.txt

  done
  
    
  # a final exit check 
  if [[ "$CURRENT_STATUS" == "resolved" ]]; then
      echo "✅ Diagnostics complete. Issue resolved!"
      # building an audit log --> just getting this output to a txt file 
  else
      echo "AI failed to resolve the issue after $MAX_LOOPS attempts."
      echo "$FINAL_SUMMARY" > log_of_agent_failed.txt
      # still make the log when failed to summarize commands tried. 
  fi
 }

# now it is, but i am not sure where it is getting that. if not, can make more types of problems within the node. 


if [[ "$RUN_CCD" = true ]]; then 
  ccd_audit 
fi 
