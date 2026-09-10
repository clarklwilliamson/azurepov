# azurepov

A golden image demo, end to end, in Azure. GitHub Actions builds it, versions it, deploys
a server from it, and proves the server came out of the oven already finished.

> **Demo only.** The two "agent" services are stand-ins. No Qualys or CrowdStrike software
> is installed and no vendor credentials are used anywhere in this repo. The point is the
> mechanism, not the agents.

## The argument

The common pattern is: pull a stock Windows Server 2022 from the marketplace, then visit
every server and do the same handful of setup steps on each one. That is slow, and worse,
it is slow *differently* each time, so no two servers are quite alike.

The alternative is to do those steps **once**, capture the disk, and give every later
server a copy of it.

This repo does exactly that with five steps:

| | Step |
|---|---|
| 1 | Windows Update disabled |
| 2 | Local admin account created |
| 3 | Windows Defender real-time protection disabled |
| 4 | "Qualys" folder + a Windows service that logs `running` on every boot |
| 5 | "CrowdStrike" folder + a Windows service that logs `running` on every boot |

## What the pipeline does

```
stock Windows Server 2022  (marketplace, pinned to an exact build)
        |
        |  the five things, once
        v
     sysprep /generalize        <- strips SID, machine name, activation
        |
        v
  Azure Compute Gallery         <- captured as version 1.0.0
        |
        |  deploy a server from that exact version
        v
   verify all five, on a machine nobody touched
```

Two jobs in [`.github/workflows/golden-image.yml`](.github/workflows/golden-image.yml):

- **build** creates a build VM, runs the five things, syspreps, captures a numbered
  gallery image version, deletes the build VM.
- **deploy** creates a server from that version, runs a verification script on it, writes
  a pass/fail table into the run summary, then deletes the server. The image version stays.

Run it from the Actions tab, or:

```bash
gh workflow run golden-image.yml -f imageVersion=1.0.0
```

## Why versioning matters

Most templates ask for a marketplace image by publisher, offer, SKU and `version: latest`.
`latest` moves. Two servers built a week apart start from different Windows builds and
nothing records which one any given server got.

A gallery image has a number. `1.0.0` is one specific disk, forever. That turns "what is
this server running" from a guess into a lookup:

```bash
az sig image-version list -g azurepov-demo --gallery-name povgallery \
   --gallery-image-definition win2022-clarkdemo -o table
```

And a template that consumes it replaces four drifting values with one identifier:

```jsonc
// before
"imageReference": {
  "publisher": "MicrosoftWindowsServer",
  "offer":     "WindowsServer",
  "sku":       "2022-Datacenter",
  "version":   "latest"          // moves
}

// after
"imageReference": { "id": "<gallery image version resource id>" }
```

## Authentication

GitHub signs in to Azure with **OIDC federated credentials**. There is no client secret,
no service principal password and no certificate in this repo or in GitHub secrets. The
only stored values are three non-sensitive identifiers plus the demo admin password:

| Secret | What it is |
|---|---|
| `AZURE_CLIENT_ID` | app registration id |
| `AZURE_TENANT_ID` | directory id |
| `AZURE_SUBSCRIPTION_ID` | target subscription |
| `LOCAL_ADMIN_PASSWORD` | generated, used for the demo local admin |

## What goes in an image and what does not

| In | Out |
|---|---|
| Patched Windows at a known build | Domain join |
| Agents installed but not activated | Group Policy |
| Local accounts, service definitions | Agent registration |
| Registry policy, service startup state | Boot diagnostics (a VM property, not an image one) |

The dividing line is machine identity. Anything that makes a machine *that specific
machine* has to happen after first boot, which is precisely what sysprep resets.

## The one thing that must be right in the real version

The demo services are harmless. Real agents are not. A security agent that has contacted
its cloud **before** the image is captured carries an identity, and every clone inherits
it, so the whole fleet collapses into one host in the vendor console and any count
reported from there is wrong.

Both vendors publish the fix, and it is a flag, not a workaround:

- **CrowdStrike** — install with `NO_START=1`, and do not reboot before capture. Each
  clone is issued its own Agent ID on first boot.
- **Qualys** — install with `GoldenImage=true`, block outbound to the Qualys platform
  during the build, set the service back to Automatic before capture. Each clone
  provisions its own UUID.

## The honest cost

A golden image needs a rebuild cadence. Six months without a refresh and you have swapped
a moving target for a stale one. The gallery does not solve that, it makes it visible: the
version list above shows how far behind you are, which is better than not knowing.

## Cost of running this

One `Standard_D2ads_v6` build VM for a few minutes, one more to verify, both deleted by the
pipeline. The gallery image version is the only thing that persists, and it is charged as
storage.

## Scope

Clean-room. Written from public vendor and Azure documentation. Contains nothing from any
client engagement.
