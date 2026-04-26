# tnr-llama

Nowadays, I periodically use a workflow that heavily utilizes LLMs for boilerplate
generation and other tedious tasks, but I've found that using some of the various
SaaS platforms out there is becoming increasingly expensive. So I've been on the
lookout for ways that I can cut costs without decreasing the quality of LLM output
and I stumbled on [Thunder Compute](https://thundercompute.com). To be clear,
this repository is not an endorsement of the platform -- but it's a tool you
can use with their services if you're strange enough to have a workflow similar
to my own.

So what I needed was (a) a service that could gracefully launch and kill
[llama.cpp](https://github.com/ggml-org/llama.cpp) on the remote server in
accordance with a customizable timeout, and (b) for that remote server to be
launchable and vaguely configurable from my [Emacs](https://www.gnu.org/software/emacs/)
installation. This repository is sort of the hack-and-slash answer to this
problem, so it does require some setup if you're going to replicate this.

## Legalities

This project is released under the [GPL-3.0](https://www.gnu.org/licenses/gpl-3.0.md)
license. Also I should note that neither Emacs nor Thunder Compute are associated
in any way with myself or any of the organizations that I currently work with.
You can use this project in accordance with the license.

## Setup

I am going to make the assumption that you already have an Emacs install going.
You may wish to take a look at other projects such as [gptel](https://github.com/karthink/gptel),
[mcp](https://github.com/lizqwerscott/mcp.el), and
[gptel-mcp](https://github.com/calebpower/gptel-mcp.el) if you want to get the most
out of your interactions with LLMs in Emacs.

In addition, I'm going to make the assumption that you've already set up an
account with [Thunder Compute](https://thundercompute.com). You can probably use
other providers, but you'll likely need to make some adjustments as I do rely on
the `tnr` binary that comes along with usage of their services.

For my protyping environment, I used the following for my machine:
```bash
tnr create \
    --mode prototyping \
    --gpu a100 \
    --num-gpus 1 \
    --vcpus 4 \
    --primary-disk 100 \
    --ephemeral-disk 40 \
    --snapshot deepseek_r2
```

I used the following the connect to the instance for initial setup:
```bash
tnr connect 0
```

While you're setting things up, you can probably use `screen` for get things
going in paralle. I installed `aria2` and created a folder at `/home/ubuntu/models`
for model permanent storage. There is a bit of a philosophy war going on regaridng
whether it is appropriate to store models long-term, as they can be easily
obtained multiple times but I opted to minimize snapshot restoration time and to
maximize availability. The supervisor script will preemptively copy the model off to
the ephemeral disk to make loading a little faster--this is just the little compromise
that I've made on my end to try to speed things up.

The model I've been working with while testing this workflow
is [DeepSeek-R1-Distill-Qwen-32B](https://huggingface.co/deepseek-ai/DeepSeek-R1-Distill-Qwen-32B)
but in theory any model should work for your hardware configuration, so long as
you're cognizant of the hardware prerequisites associated with your model. You can
grab that with `aria2c`; just make sure that you've put it in the proper folder
and that you've updated the script accordingly.

I cloned [llama.cpp](https://github.com/ggml-org/llama.cpp) to `/home/ubuntu/llama.cpp`
built it in the following manner:
```bash
cd /home/ubuntu/llama.cpp
mkdir -p build && cd build
cmake .. -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release
cmake --build . --config Release -j $(nproc)
```

You should probably build this in the way that makes the most sense for your environment.

I installed `supervisor.sh` at `/home/ubuntu/supervisor.sh`. The script should install
and/or make sure that the most updated version of `tnr` is installed. You should be able
to manually invoke `/home/ubuntu/supervisor.sh` at this point in time, provided that your
permissions are set properly. If everything is working properly, you should also be able
to `tail -f /tmp/llama.log` to see if `llama.cpp` is actually running the model properly.

When you've finished with this setup, you'll want to make sure that you create a snapshot
so that you can automatically launch it. It's really important that the name of the
snapshot indicated in `supervisor.sh` matches the name of the actual snapshot--so there's
a bit of a chicken-and-the-egge scenario in which you'll need to know the name of the
snapshot before you actually make the thing. So, update the script and then clean up
any working files if you tried to test the supervisor. You'll want to kill any instances
of `llama-server` that are lingering around (`ps -aux` and `kill -9` are your friends
here), and you'll want to remove any existing lingering files in `/tmp` (including the
log and lockfile).

Once you're ready to create the snapshot, you can do `tnr snapshot create`, select the
running instance, and then enter the name that you've _already chosen_. It may take a
bit to actually generate the snapshot, but you should be able to `tnr delete 0` while
you wait so you can save on costs by not having a running instance just floating around.

## Configuration

For Emacs, you'll want to install this the way you normally would install a custom
plugin. Chances are you'll want to have something like this:

```lisp
(use-package tnr-llama
  :vc (:url "https://github.com/calebpower/tnr-llama")
  :custom
  (tnr-llama-mode "prototyping")
  (tnr-llama-num-gpus 1)
  (tnr-llama-snapshot "llama-snapshot")
  (tnr-llama-idle-grace 600)
  ;; Optional: Add keybindings for quick access
  :bind (("C-c l l" . tnr-llama-launch)
         ("C-c l d" . tnr-llama-destroy)
         ("C-c l s" . tnr-llama-status)
         ("C-c l r" . tnr-llama-script-restart)))
```

Consult the following table for different values you can configure.

| Parameter                | Type   | Description |
|:-------------------------|:-------|:------------|
| tnr-llama-bin-path       | string | Denotes the path of `tnr`. Defaults to `tnr`. |
| tnr-llama-mode           | string | Use 'prototyping' or 'production'; see `tnr create --help` for more info. Default to `prototyping.` |
| tnr-llama-gpu            | string | Specifies GPU family. See `tnr create --help` for more info. Defaults to `a100`. |
| tnr-llama-num-gpus       | int    | Specifies the number of GPUs to use in the system. See `tnr create --help` for more info. Defaults to `1`. |
| tnr-llama-vcpus          | int    | Specifies the number of vCPUs to use in the system. See `tnr create --help` for more info. Defaults to `4`. |
| tnr-llama-primary-disk   | int    | Specifies the number of gigs in the primary disk. See `tnr create --help` for more info. Defaults to `100`. |
| tnr-llama-ephemeral-disk | int    | Specifies the number of gigs in the ephemeral disk. See `tnr create --help` for more info. Defaults to `30`. |
| tnr-llama-snapshot       | string | Specifies the name of the snapshot to use when creating a new instance. See `tnr create --help` for more info. Default to `llama-snapshot`. |
| tnr-llama-remote-script  | string | Specifies the path to the remote script to launch on instance startup. |
| tnr-llama-port           | int    | Specifies the port on which llama should be exposed. Defaults to `8080`. |
| tnr-llama-ssh-user       | string | Specifies the SSH user for dispatching commands to the remote server. |
| tnr-llama-ssh-key        | string | Specifies the local path to the SSH private key. |
| tnr-llama-ssh-id         | string | Specifies the name of the SSH key, as configured in Thunder Compute. |
| tnr-llama-idle-grace     | int    | Specifies the number of seconds before the remote server should self-destruct when idle. |

So, one thing that you ought to do before running this thing is to make sure that
you've added your SSH public key to Thunder Compute's online portal, and given it
a snazzy name. Your Emacs script will need to know it so that the key can be
authorized and so the tunnel can be established.

## Usage

Once you've installed this thing, you can launch with `tnr-llama-launch`. You can
also destroy it with `tnr-llama-destroy`. Here's a list of commands you might
find helpful.

| Command             | Description                                                                                       |
|:--------------------|:--------------------------------------------------------------------------------------------------|
| tnr-launch          | Start the server instance, launch `llama-server`, and forward the port.                           |
| tnr-destroy         | Kill the server instance.                                                                         |
| tnr-script-restart  | Restart the supervisor and llama instance, but don't actually restart the server instance itself. |
| tnr-status          | Figure out where we're at in the launch workflow.                                                 |
