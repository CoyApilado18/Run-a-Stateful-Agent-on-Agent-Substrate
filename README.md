path: /mnt/d/Projects/NextWork/
# 30 Second Summary
Most AI agents sit idle between requests, but their infrastructure keeps consuming resources. Running more agents usually means paying for more capacity that spends most of its time waiting.  

In this project, I will run `Agent Substrate` with `kagent` on a local Kubernetes cluster. A troubleshooting agent diagnoses a broken app before releasing its worker between messages.  

## What I'll Build
Picture a sleeping troubleshooting chat remembering its earlier diagnosis after every original worker has been replaced.  

Architecture diagram showing a local Kubernetes cluster running inside Docker, with kagent, Agent Substrate, and a shared WorkerPool managing sandboxed agents, snapshot storage, and Gemini API requests.
[alt images](high-level-overview-diagram.png)  


By the end of this project, you'll have:  
• A live operations view that shows how a `WorkerPool` shares ready workers across agent chats.  
• A read-only diagnosis that identifies the misspelled image behind a broken web Deployment.  
• A `stateful scale-to-zero` proof where the same Actor returns from a snapshot on replacement capacity with its earlier conversation intact.  

Extra Credit: Add four more agents to compare five chats against the smaller number of busy workers in the live savings table.  

OS = Windows11 with Ubuntu WSL  


# Step 1. Launch Your Local Agent Platform

In this step, I'll:  
- Prepare Docker for the setup script's host checks.  
- Clone the starter repo to install Agent Substrate with Kagent on my local K8s cluster and this will also protect my Gemini API key.  
- Launch the local cluster and inspect its ready worker capacity.  

## Prepare and verify your host  
The installer needs at least 4 Docker CPUs and 6 GB of Docker memory. It downloads about 5.5 GB of files, so keep about 10 GB of disk space free.  

The setup path differs by operating system. Choose your platform below to prepare Docker and the terminal that runs the project, but keep Docker's default resource settings unless the preflight reports a problem.  

- Keep this Ubuntu terminal open for the project commands. PowerShell is only used if WSL needs installation.
```bash
for tool in git curl tar awk nano; do
  command -v "$tool" >/dev/null && echo "$tool: ready" || echo "$tool: missing"
done
docker info >/dev/null 2>&1 && echo "docker: ready" || echo "docker: unavailable"
```

Output:
[alt images](prereqs-check.png)  


## Clone the repository and protect your key
The starter repository contains the scripts that build the platform in the correct order. `Git` copies those scripts to your computer as one folder.  

💡 Why use the repository installer?  

A manual installation requires separate downloads plus certificate configuration and component ordering. The repository keeps this project focused on the Agent Substrate lifecycle.  

We'll still inspect the resulting Kubernetes resources through the status script and `kubectl`.  

I'll clone the starter repository, and create its local credential file: 
```bash
cd ~/Desktop
git clone https://github.com/Nik-1019/agent-substrate-kagent-nextwork.git agent-substrate-kagent-nextwork
cd agent-substrate-kagent-nextwork
cp .env.example .env
```
The completed command returns to the terminal inside `agent-substrate-kagent-nextwork` directory. The repository now contains its setup scripts plus the manifests folder.  

## Grab a Gemini API key
A Gemini API key is a live credential. Creating it exposes the value briefly, so I'll keep it private and won't include it in my shared notes.

• Open [Google AI](https://aistudio.google.com/apikey) Studio.  
• Sign in with Google account.  
• Create a Gemini API key.  
• I'll Copy the new key.  
• Return to my terminal inside `agent-substrate-kagent-nextwork` directory.  
• Open the credential file with `nano`:
```bash
nano .env
```
• I'll paste the API key in `GEMINI_API_KEY=`.  

💡 Why edit this file?  
The installer reads our credential from `.env`. The repository excludes this local file from `Git`. Only the value after `GEMINI_API_KEY=` needs to change. The key stays hidden from the setup output.  

• Press `Ctrl+O` to write the file.  
• Press `Enter` to confirm the filename.  
• Press `Ctrl+X` to close nano.  


## Install and inspect the platform
The setup script checks the host before creating anything. It then downloads the pinned tools and builds the cluster in dependency order.  

The first run can take 5 to 10 minutes while Docker downloads images. Quiet stretches during this run are expected.  

- Create the cluster and install the platform by running:
```bash
./setup.sh
```

💡 What does the installer do?  
• It downloads pinned tools into `./bin`.  
• It creates a local kind cluster named `kagent` with Kubernetes `v1.37.0`.  
• It installs Agent Substrate `v0.6.0-alpha3` with kagent `v1.0.0-alpha16`.  
• It creates the WorkerPool capacity and opens the UI tunnel at `http://localhost:8080`.  

The setup script used Docker to create the kind node that hosts your local Kubernetes cluster. Docker Desktop can now show that infrastructure as a running container.  

Open the Containers view for this check. Docker Desktop's Kubernetes view manages a separate optional cluster.  

• Press the Windows key to open Start search.  
• Type Docker Desktop into Start search.  
• Press Enter to open Docker Desktop.  
• Select Containers in the left sidebar.  
• Enter kagent in the Search field.  
• Select the running container whose name includes kagent.  
• Select the Stats tab.  
• Leave the start, stop, pause, and delete controls unchanged.  

You should see live CPU and memory measurements. This activity belongs to the kind node hosting your local cluster while your commands continue to run in Ubuntu WSL.
[alt images](docker-desktop-cpu.png)


Before you inspect the result, which hot-desk resources do you expect to see before any chat exists?  
Inspect the platform and its WorkerPool by running these commands:
```bash
./status.sh
./bin/kubectl get workerpool -n kagent
```
Output:  
[alt images](status-sh.png)  


💡 How to read the result  
• The `WORKERPOOL` named `kagent-default` is the managed group of ready desks.  
• Each worker row (`WORKER POD`) represents one ready desk that can host an `Actor`.  
• The `ROUTER` is the receptionist that receives future requests and directs them to the current worker.  
• The `ACTORS` table reports that no Actors exist because no chat has started.  
• The UI address is `http://localhost:8080`.  

Enter `http://localhost:8080` in your browser address bar.  
Output:
[alt images](kagent-localhost.png)  


💡 What is kagent?  
kagent is an open-source, Kubernetes-native platform for running AI agents. It defines agent behavior and runtime as Kubernetes resources, then runs each conversation inside Agent Substrate.  

The Substrate page shows WorkerPools, workers, ActorTemplates, and Actors. Empty ActorTemplate and Actor tables are expected here because you have not created an agent or started a conversation yet.  

• Click Substrate in the left sidebar.  
• Find `kagent/kagent-defaul`t` in the Worker Pools table.  
• Confirm that Replicas shows `1` or more.  
• Confirm that the Workers table lists at least one pod assigned to kagent-default.  
• Confirm that the Actor Templates table has no entries yet.  

[alt images](worker-pools-tbl.png)  

Our local agent platform is live. The reusable worker desks are ready for the first agent conversation.  


# Step 2. Build Your Troubleshooting Agent
Our local `Agent Substrate` platform is running. Its `WorkerPool` has ready `workers`. Those workers need an agent definition before they can host a conversation.  

In this step, I will use `kagent` to create `ops-buddy` (our troubleshooting agent) from a shared `template` and `harness`. I will confirm its   `golden snapshot` is ready before a message creates the first `Actor`. I'll:  
- Create ops-buddy in the kagent namespace.  
- Configure its shared template plus harness.  
- Confirm its golden snapshot is ready without creating a chat Actor.  

## Create the ops-buddy agent 
The template is the agent's playbook. The harness connects that playbook to the workers that run it.

• Switch back to the browser tab showing the kagent UI at `http://localhost:8080`.  
• Select `Agents` in the navigation.  
• Click `New Agent.`  
• Enter `ops-buddy` in the Name field.  
• Select `kagent` in the Namespace field.  
• Keep `Reference` selected.  
• The form now identifies `ops-buddy` as a Reference agent in the kagent namespace.  
• Choose `kubernetes-agent` in the `Shared template` field.  
• Choose `substrate-harness` in the `Harness` field.  
• Click `Create agent`.  

💡 How the pieces fit together
The template gives the agent its model, instructions, and read-only Kubernetes tools. It acts as the job description for `ops-buddy`.  
The `harness` connects that job description to the running platform. Here, `substrate-harness` sends the work to the kagent-default WorkerPool.  


## Wait for the golden snapshot
Creating the agent also prepares a golden snapshot. This saved starting point lets the first chat wake faster because the platform does not rebuild the agent from scratch.

• Locate the `ops-buddy` row in the Agents table.  
• Use the refresh control above the table while the agent is preparing.  
• Wait until the Status value reads `Ready`.  

[alt images](ops-buddy-ready.png)

That preparation is complete. `ops-buddy` now has a ready starting state for its first conversation.  


## Verify the template without starting a chat
A ready agent and an active chat are different things. The prepared agent waits as a template until the first message creates a chat Actor.

Before you run the check, do you think a ready agent already has a chat Actor?  
• Switch back to the terminal from earlier.  
• Verify the agent state by running this command:  
```bash
./status.sh
```
[alt images](status-sh-report.png)  

💡 What does the status report prove?  
• The `TEMPLATES` table shows ops-buddy with a ready golden snapshot.  
• The `ACTORS` table is empty because no chat has started.  
• The `kagent-default WorkerPool` still has room for the first conversation.  
• The `router` is ready to send the first message to an available worker.  

We have reached the clean starting point. The agent is prepared, no chat exists yet, and worker capacity is waiting. The Substrate page shows the same state as a diagram. It lets you see the ready template and confirm that no chat Actor is running.  

• I'll Switch back to the kagent UI in my browser.  
• Select the Substrate page.  
• Locate the ready Actor template associated with ops-buddy.  
• Check the Actors area for active chat sessions.  

I should see the ready Actor template for ops-buddy. The Actors area is empty because I have not sent a message.  
[alt images](ops-buddy-actor.png)


# Step 3. Diagnose the Broken Deployment
Our agent needs a real problem before it can show what it knows. I will create a small, controlled failure inside the local Kubernetes cluster.
After ops-buddy diagnoses the failure, Agent Substrate saves the chat Actor in a snapshot. The WorkerPool then gets its worker back for another conversation.  

In this step I'll:  
• Deploy the web workload and inspect its pod state.  
• Enable request polling and run a two-message diagnosis with ops-buddy.  
• Confirm that the chat Actor suspends with saved state and free worker capacity.  


## Create the web Deployment
A `Deployment` tells Kubernetes which app image to keep running. You will create one named `web` with a specific image tag, then inspect what happens. 

• Switch back to your Terminal. 
• Create the web Deployment by running this command:  
```bash
./bin/kubectl create deployment web --image=nginx:1.27-alpne
```

The terminal confirms that the Deployment was created. Kubernetes now tries to start its pod. 
[alt images](k-deploy.png)  


💡 What does this command do?  
The create deployment web portion adds a Deployment named web to your local cluster.  
The `--image=nginx:1.27-alpne` value tells Kubernetes which container image the Deployment should run.  


I'll inspect the `web` pod by running the `kubectl get pods` command. The command reads the pods in our current namespace. We should see the web pod reach `ImagePullBackOff` because `nginx:1.27-alpne` contains the intended spelling error.  
[alt images](k-get-po.png)

• Wait a few seconds for Kubernetes to try the image download.  
• Run the pod inspection command again.  
• Leave the web Deployment unchanged.  


## Enable polling and ask ops-buddy
The Substrate page shows the chat moving through each stage. A worker is the temporary seat that runs the Actor while it answers.  
• I'll return to the kagent UI in my browser.  
• Select the Substrate page from the navigation.  
• Click Request polling: disabled.  

[alt images](request-polling.png)  


• Create a second browser tab.  
• Let's return to the kagent Agents surface in the second tab.  
[alt images](agents.png)

• I'll select `ops-buddy` to open its chat and paste this troubleshooting prompt into the chat input:  
```bash
My app called web isn't working. Can you find out why?
```

💡 Why this prompt works  
Naming `web` gives `ops-buddy` a specific Deployment to inspect. Asking what is wrong keeps the read-only agent focused on diagnosis instead of making changes.  

• I'll submit the message with the chat send control.
• Return to the Substrate tab while the request runs.  
• I should see the Actor claim a worker inside a `gVisor sandbox` while it answers.  
[alt images](actor-space.png)

• When the reply finishes, the Actor moves to `SUSPENDED` and the worker becomes free again.  
[alt images](actor-suspended.png)  

• Return to the `ops-buddy` chat after the lifecycle settles.

The reply identifies nginx:1.27-alpne as the misspelled image tag. Leave the Deployment broken so the next step can prove that the same chat remembers this diagnosis.  

• I'll go back to the terminal from earlier.  
• Inspect the saved diagnosis and freed worker capacity by running this command:
```bash
./status.sh
```

In `ACTORS`, `ops-buddy` should show `SUSPENDED` with a higher snapshot count. In `WORKERS`, the worker shows `BUSY?: free`, so the conversation keeps its diagnosis without reserving compute.  
[alt images](status-sh-actors.png)  


📣 This is the scale-to-zero moment  
The worker finished the task and returned to the pool. The conversation stayed ready inside the Actor snapshot.  

• I'll go back to the existing ops-buddy chat and send this follow-up message:  
```bash
What evidence supports your diagnosis, and what image tag should I use to fix it? Do not change anything.
```

• Submit the message with the chat send control.  
• Return to the Substrate tab while the request runs.  
• Return to the ops-buddy chat after the reply finishes.  

[alt images](second-prompt.png)  


The agent should connect `ImagePullBackOff` to the misspelled `nginx:1.27-alpne` tag. It should recommend `nginx:1.27-alpine` without changing the Deployment.

• Return to the terminal from earlier.  
• Inspect the second saved turn and freed worker capacity by running this command:  
```bash
./status.sh
```

[alt images] (comparison.png)

The snapshot count should rise again after the second reply. The Actor should return to `SUSPENDED` with the worker free.  
The `web` pod remains in `ImagePullBackOff`, ready for the continuity test. Its diagnosis now lives inside a suspended Actor.  

Our diagnosis is stored while worker capacity is free. Next, I will replace the original workers and wake the same conversation on new capacity.  


# Step 4. Replace Workers and Resume the Actor
`ops-buddy` found why the `web` Deployment was broken. Its Actor saved that diagnosis in a snapshot before going to sleep.  

Now I'll remove every worker that could have held the conversation. If `ops-buddy` remembers its diagnosis after replacements take over, we have direct proof that its memory lives in the Actor snapshot.  


## Replace the WorkerPool pods
A WorkerPool keeps a group of workers ready for new requests. When one pod disappears, Kubernetes creates another until the pool is full again.  

• I'll go back to the terminal from earlier inside the `agent-substrate-kagent-nextwork` repository.  
• List the current runtime state by running this command:  
```bash
./status.sh
```

The workers section should still gives us the original pod names to compare later and the Actor should still show `SUSPENDED` because we have not sent another message. The capacity summary shows a ready worker is available for the next request.  

[alt images](initial-worker-pods.png)

• First, I'll take note of the worker pod names `kagent-default-67d8cc74bd-mnr4q` and `kagent-default-67d8cc74bd-skzz8`.  
• Delete every current worker pod by running the command below.  
```bash
k -n kagent delete po -l ate.dev/worker-pool=kagent-default
```
[alt images](deleted-worker-pods.png)  

The suspended Actor keeps its snapshot while the WorkerPool rebuilds.  

• Watch Kubernetes create replacement worker pods by running the command below or just the same command without the `-w` option.
```bash
k -n kagent get po -w
```

[alt images](new-pods.png)  


• Check the recovered WorkerPool and suspended Actor by running this command:
```bash
./status.sh
```

[alt images](recovered-worker-pool.png)  


📣 The worker is disposable  
We've deleted every original worker pod. The Actor and its diagnosis remained intact while Kubernetes rebuilt the pool.  

The `WORKERPOOL` line should report every replacement ready under new pod names. In `WORKERS`, `ACTIVE` with `BUSY?: free` confirms that replacement capacity is available.  

## Resume the same Actor
`Resume` wakes a sleeping Actor from its latest snapshot on any worker with room. The `router` sends the next message to that restored conversation.  

🚨 Checkpoint support varies by host  
On macOS or Windows, Docker Desktop can fail Agent Substrate's gVisor sandbox checkpoint path even when setup and worker replacement succeed.  
If the next message cannot resume the Actor, your earlier work may still be intact. Docker Engine on Linux provides the most reliable local lifecycle path.  

• I'll switch back to the browser tab containing our existing ops-buddy chat and send this exact follow-up message:  
```bash
What did I ask you earlier, and what fix did you recommend?
```  

The reply should identify our earlier question about the broken web app. It should recall that `nginx:1.27-alpne` needs to change to `nginx:1.27-alpine`.  
[alt images](earlier-msg-reply.png)


💡 Why does this message prove continuity?  
The follow-up makes sense only if the chat remembers the first question and diagnosis. A correct answer proves the resumed Actor received its saved conversation.  

• I'll go back to the terminal from earlier after the reply finishes and will inspect the resumed Actor immediately by running this command:
```bash
./status.sh
```

[alt images](last-wake-up.png)  


💡 What does the resumed state show?  
• The `LAST WAKE-UP` value records when the Actor moved onto replacement capacity.  
• The `SUSPENDED` state shows the finished chat released its worker again.  
• The newest snapshot now contains the first diagnosis and the follow-up reply.  

The same conversation answered from replacement capacity with its earlier diagnosis intact. That is `stateful scale-to-zero`: memory survives while workers come and go.  

• I'll go back to the existing ops-buddy chat.
• Send this second follow-up message:
```bash
Before I change anything, summarize the root cause, the corrected image tag, and the two checks I should make after the repair. Do not make any changes.
```  

The reply should name `nginx:1.27-alpne` as the root cause and `nginx:1.27-alpine` as the correction. It should suggest checking that the pod reaches `Running` and that the Deployment stores the corrected image.  

[alt images](summary-root-cause.png)  


• Let's inspect the second resumed turn by running the status shell script:  
```bash
./status.sh
```

The expected output of the Actor should be suspended again with another saved snapshot. This repeated cycle proves one conversation can resume across several turns after worker replacement.  

[alt images](actor-suspended1.png)  


## Repair the web Deployment
The `web` Deployment still uses the misspelled image that caused `ImagePullBackOff`. Correcting the tag tells Kubernetes to replace the failed pod with a working one.  

• Correct the image used by the nginx container by running the command below with the correct spelling; `alpne` -> `alpine`.
```bash
./bin/kubectl set image deployment/web nginx=nginx:1.27-alpine
```

[alt images](correct-image.png)  


• Check the repaired workload by the command below and the `web` pod should be in `RUNNING` status.  
```bash
./bin/kubectl get pods
```

[alt images](web-pod-running-status.png)  


• Confirm the image stored in the web Deployment:  
- using `jsonpath`:  
```bash
./bin/kubectl get deployment web -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```  

or  

- `grep` the image  
```bash
k describe deploy web | grep -i "image" -A5
```  

[alt images](grep-web-deploy.png)  


The image update changed the web Deployment template from `nginx:1.27-alpne` to `nginx:1.27-alpine`. Kubernetes used the corrected template to replace the failed pod. The `RUNNING` state shows the replacement started successfully. The `grep` or `JSONPath` check read the image directly from the Deployment template. Seeing `nginx:1.27-alpine` confirms the typo is gone Together, these checks prove the saved configuration and running workload now agree.  


# Extra Credit: Five Agents, Fewer Workers
One sleeping chat can release its worker. What happens when five separate chats all share the same kagent WorkerPool? I will create five independent chats that inspect the same Kubernetes cluster. The live view will show each Actor waking, using capacity, and going back to sleep.  

In this extra credit, I'll: 
• Add four predefined agents that reuse the existing template and harness.  
• Confirm that all five agents are ready.  
• Use the live status view to observe all five chat lifecycles.  
• Capture the final comparison between agent chats and busy workers.  


💡 Why shared workers matter  
`Agent Substrate` places an Actor on any available worker only while that chat needs to answer. A saved snapshot keeps the conversation after the Actor stops using the worker.

`Suspension` returns the worker to the shared pool. This `stateful scale-to-zero` pattern lets many sleeping chats share a smaller amount of active capacity.  


## Add four shared agents
The repository includes four agents for this capacity test. They reuse kubernetes-agent and substrate-harness, so they share the existing runtime instead of creating four more stacks.  
• I'll switch back to the Bash terminal from earlier and create the four predefined agents and list every agent by running these commands:
```bash
./bin/kubectl apply -f manifests/secret-mission-agents.yaml
./bin/kubectl get agent -n kagent
```
[alt images](addtl-4agents.png)  

Our five-agent test is assembled; `ops-buddy`, `day-shift`, `night-shift`, `on-call`, and `intern` with a `Ready` status.  


## Start the live lifecycle view
Watch mode refreshes the status every two seconds and keeps that terminal busy. I'll use a second terminal so the lifecycle view stays visible while we send messages in the browser.  
• I'll create a second terminal in the existing `agent-substrate-kagent-nextwork` folder.  
• Start the live lifecycle view by running this command:  
```bash
./status.sh --watch
```

💡 What does watch mode show?  
The live report refreshes the workers, Actors, router, wake-up times, and savings table every two seconds. You can watch capacity move as each chat starts and finishes.  

• I'll leave the live status view running until the final savings table has been captured. I should see ready replacement workers in `kagent-default`. The existing `ops-buddy` Actor should start in its suspended state.  

[alt images](status-watch-sh.png)  


## Message all five agents 
Kagent Agents page listing the five agents available for separate chats. 

[alt images](message-all-5agents.png)  

Each chat Actor keeps one conversation separate from the others. All five Actors can still take turns using the same workers.  

• Keep the live status terminal visible beside your browser.  
• Return to the kagent UI at http://localhost:8080.  
• Open the `day-shift` chat from the Agents surface and send this prompt:
```bash
Which namespaces exist in this cluster?
```

[alt images](day-shift-chat.png)  

The live view shows the day-shift Actor take a worker for its reply. The router sends the message to whichever worker has room.

• Open the `night-shift` chat from the Agents surface and send this prompt:
```bash
Which namespaces exist in this cluster?
```

[alt images](night-shift-chat.png)  


The live view adds a separate night-shift Actor. Its conversation stays separate from day-shift even though both use the same pool.


• I'll open the `on-call` chat from the Agents surface and send this prompt:
```bash
Which namespaces exist in this cluster?
```

[alt images](on-call-chat.png)

The on-call Actor borrows a worker for its reply. Its saved conversation remains available after it goes back to sleep.  

• Open the intern chat from the Agents surface and send this prompt:  
```bash
Which namespaces exist in this cluster?
```

[alt images](intern-chat.png)  

The live view now tracks the intern Actor as a fourth new conversation. Its worker returns to the pool after the reply finishes.

• I'll go back to the existing `ops-buddy` chat and send this prompt:  
```bash
Which namespaces exist in this cluster?
```
[alt images](ops-buddy-chat.png)  


The existing `ops-buddy` Actor wakes with its saved conversation for one more reply. It releases the worker again when the The table counts 8 separate chats. Once their replies finish, the Actors sleep and fewer than 8 workers stay busy. 

[alt images](savings-table.png)  


💡 Why send the same prompt?  
We sent the same question to five separate chats while the live status view tracked their Actors. Each message created the same kind of work for the platform.  

One Actor woke for each reply and borrowed an available worker. After answering, it saved its state and suspended so the worker could serve another chat.  
`AGENT CHATS` counts the separate conversations stored by the platform.  
`AWAKE ACTORS` counts the conversations processing a message right now.  
`WORKERS BUSY` shows how much shared capacity those active conversations currently use.  
`PODS WITHOUT SUBSTRATE` shows the hypothetical number of continuously running pods in a one-pod-per-chat design.  

Using one prompt keeps the workload consistent. Any change in the table now reflects how Agent Substrate schedules separate conversations instead of differences between easy and difficult requests.  

This is useful for capacity testing because teams can increase the number of independent sessions while holding the task constant. The result helps them size a shared worker pool without keeping one pod active for every idle support, operations, or research chat.  

# Clean Up Your Resources
Deleting the environment removes the local cluster permanently. You can recreate it later by cloning the repository again.  
Switch back to the Bash terminal in `agent-substrate-kagent-nextwork`.  

• Delete the local cluster and UI tunnel by running the repository's teardown script:  
• Keep future prompts synthetic and non-sensitive.  
```bash
./teardown.sh
```

The script deletes the local kind cluster named kagent and it also closes the kagent UI tunnel. Your repository stays on disk and your remote Gemini API key stays active.  


The next action removes the credential from this project. The remote key remains active until you delete it in Google AI Studio.  

• Remove the local credential file:
```bash
rm .env
```


Special thanks to [Nextwork](https://nextwork.ai/)  

---END---