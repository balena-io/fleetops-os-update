# Overview

To perform an upgrade using this repo (with very specific parameters in terms of source and target host OS versions):

1. First, create a `params` file locally to use (`cp params.example params`)
1. Set a target commit in the created `params` file
1. Create a file called batch with line-separated UUIDs
1. Run `./run_preupdate.sh` to confirm and prepare all devices in `batch` are ready for upgrade
1. If `grep -i fail preupdater.log` returns no output, the update can proceed. Otherwise, some supervisor updates may be required.
1. Finally, run `./run.sh` to perform the actual upgrade and reboot into the new host OS
