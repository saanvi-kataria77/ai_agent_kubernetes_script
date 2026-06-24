# SRE Agent: Autonomous Kubernetes Diagnostic Loop 

> *A flexible, dual-engine SRE agent that mitigates Kubernetes cluster failures locally using Ollama (Phi-3) or via the cloud using the Groq API.*

## 🌟 Highlights

- **Dual-Engine Architecture:** Seamlessly toggle between a lightweight local edge-AI (Ollama/Phi-3 using ~2.5GB RAM) and a high-performance cloud model (Groq API).
- **Deterministic JSON State Machine:** Uses jq to filter cluster events down to critical warnings, enforcing a strict JSON-only communication schema with the LLM.
- **Autonomous Circuit Breaker:** Implements a state machine loop that iteratively runs diagnostics and feeds terminal standard output (stdout/stderr) back to the AI, safely capped at a 5-iteration circuit breaker.
- **Human-in-the-Loop Validation:** Halts execution before running any command, ensuring the operator retains ultimate approval power.
- **GitOps & CI/CD Compliant:** Enforces strict imperative, non-interactive commands (no vim or kubectl edit) to prevent configuration drift and maintain infrastructure-as-code integrity.

## ℹ️ Overview

### What the software does 
This script acts as an autonomous Site Reliability Engineering (SRE) assistant. When triggered, it scans a Kubernetes namespace for warning events, parses the telemetry into a structured JSON payload, and passes it to an LLM. The AI agent analyzes the warnings, deduces the root cause, and formulates the exact kubectl command needed to investigate or resolve the issue.
It handles automated argument parsing (queue-shifting flags) to configure the target LLM endpoints and injects artificial pacing to avoid API velocity bans.

### How it works
The agent operates on a continuous feedback loop driven by three core functions:
- ```_ask_llm()```: Ingests the initial cluster warning JSON and outputs a structured diagnosis and recommended command.
- ```_human_in_the_loop()```: Intercepts the workflow, displays the AI's reasoning, and waits for user validation (y/n). If approved, it executes the command within an error-catching sandbox (set +e) and captures the resulting terminal output.
- ```_ask_llm_again()```: Ingests the terminal output from the previous execution. The AI evaluates if the output indicates a resolved state or if further debugging is required, generating the next command and perpetuating the while loop until the issue is solved.

### Integration in AI Systems
This script serves as a foundational blueprint for integrating LLMs into cloud-native orchestration. The architecture can be easily expanded to:
Act as a background worker in an automated CI/CD pipeline (by bypassing the human-in-the-loop flag).
Ingest metrics from Prometheus or Grafana instead of raw kubectl events.
Orchestrate multi-agent workflows where a "Diagnostic Agent" (Phi-3) hands off a mitigation plan to an "Execution Agent."

## ⬇️ Installation

### Prerequisites
To run this script, your local machine must have the following installed:
- ```kubectl``` (Configured to a running cluster, e.g., Minikube)
- ```jq``` (Command-line JSON processor)
- ```curl``` (For HTTP requests)

**Local Engine (Default)**
- Install [Ollama](https://ollama.com)
- Pull the Phi-3 model: ```ollama run phi3``` (Ensure the server is running on port 11434).

**Cloud Engine**
A free [Groq API Key](https://groq.com)

### Setup 
Clone the repository:
- ```git clone https://github.com/saanvi-kataria77/ai_agent_kubernetes_script.git```
- ```cd kubernetes_script```
Make the script executable:
```bash 
 $ chmod +x kubernetes_script.sh
```

## 🚀 Usage
Ensure your target Kubernetes cluster is running and your ```kubectl``` context is set properly.
**1. Run Locally**
By default, the script routes all traffic to your local Ollama server.
```bash
$ ./kubernetes_script.sh --ccd_audit
```
**Run using Cloud (Groq API)**
To leverage a larger model for complex debugging, set your API key as an environment variable and pass the ```--cloud``` flag. Order of arguments does not matter.
```bash
$ export GROQ_API_KEY="your_api_key_here"
$ ./kubernetes_script.sh --cloud --ccd_audit
```

**Interaction Flow**
When the script runs, it will pause and prompt you:
```text
Here is the recommended command to run: kubectl get pod komodor-agent-admission-controller-77f68cfd4-bbjgg -o yaml
Why: The pod is failing its readiness probe. Pulling the full YAML will expose the specific container configuration causing the failure.
Would you like to run this command? Answer y/n.
```
Type ```y``` to execute and feed the logs back into the state machine, or ```n``` to cleanly exit the script!








