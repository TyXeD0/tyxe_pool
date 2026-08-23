# Dynamic EXIT provisioner

Milestone after the dynamic `mtproxyl-egressd` cutover.

The provisioner is installed on ENTER and provisions a clean EXIT over SSH.

Safety rules:

- existing EXIT nodes are not touched by provisioner installation;
- SSH password/private key is used only for the operation and is not stored in `nodes.d` or job logs;
- add/remove operations are serialized;
- a new node is committed to the registry only after AWG, tunnel, Telegram TCP and node-agent checks succeed;
- failed add rolls back only the candidate node;
- deleting an active node first moves production away from it;
- deleting the last node requires an explicit BLOCK or DIRECT fallback;
- remote cleanup failure does not prevent safe local removal from ENTER.

Supported authentication modes:

- `auto`: existing SSH credentials / ssh-agent;
- `password`: transient password;
- `key`: transient private key.

Recommended first validation target: a disposable clean Ubuntu 24.04 EXIT.
