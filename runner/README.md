# A GitHub self-hosted runner for Repeato

GitHub's free plan gives a fixed number of Actions minutes a month; Repeato runs out. A self-hosted runner costs no minutes: jobs run on a machine you own. Two options:

| | Laptop (Windows) | Small Linux VM |
|---|---|---|
| Cost | none | a few hundred rupees a month (e2-small or similar) |
| Runs | deploy workflows (`DEPLOY_RUNNER`) | deploy workflows and CI (`CI_RUNNER`), because CI uses bash steps and Docker service containers |
| Available | only while the laptop is on and the runner runs | always |

Both register at the **organization** level (`repeato-in`), so one runner serves all four app repositories.

## How the workflows choose the runner

Every job in the app repositories has

```yaml
runs-on: ${{ vars.DEPLOY_RUNNER || 'ubuntu-latest' }}   # deploy-staging.yml, deploy-production.yml
runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}       # ci.yml
```

`vars` is allowed in `runs-on` (GitHub's context availability table: `jobs.<job_id>.runs-on` may use `github`, `needs`, `strategy`, `matrix`, `vars`, `inputs`); actionlint 1.7.7 accepts these files. A variable that is not set gives an empty string, so `||` falls back to `ubuntu-latest`. A self-hosted runner is picked by one of its labels: the value of the variable is that label (for example `repeato-laptop`). Set it per repository (Settings → Secrets and variables → Actions → Variables) or once as an organization variable.

To go back to GitHub's machines, delete the variable.

## Laptop install (Windows, PowerShell)

1. GitHub → organization `repeato-in` → Settings → Actions → Runners → **New runner** → Windows x64. GitHub shows a one-time registration token (valid for one hour).
2. In an ordinary (not administrator) PowerShell:

   ```powershell
   New-Item -ItemType Directory C:\actions-runner | Out-Null
   Set-Location C:\actions-runner
   $version = '2.338.2'
   Invoke-WebRequest "https://github.com/actions/runner/releases/download/v$version/actions-runner-win-x64-$version.zip" -OutFile runner.zip
   Expand-Archive runner.zip -DestinationPath . ; Remove-Item runner.zip
   ./config.cmd --url https://github.com/repeato-in --token <TOKEN FROM STEP 1> --name ritesh-laptop --labels repeato-laptop --runnergroup Default --work _work --unattended
   ```

   Check the newest version on https://github.com/actions/runner/releases (2.338.2 on 2026-11-11).
3. Start it when you want deploys to run: `C:\actions-runner\run.cmd` (stop with Ctrl+C; jobs wait in the queue while it is off). To have it start with Windows instead, run the `config.cmd` line of step 2 in an **administrator** PowerShell with `--runasservice` added; it registers a Windows service named `actions.runner.repeato-in.ritesh-laptop`.
4. The machine needs what the scripts call: `pwsh` 7.4+, `git`, `node` 22, `bun` 1.3.14, `gcloud`, `flutter` 3.41.5, `firebase` (installed by the script if missing), `vercel` (installed by the script). The workflow `setup-*` steps install node, bun, gcloud and flutter into the runner's tool cache if they are missing.
5. Set the variable `DEPLOY_RUNNER` = `repeato-laptop` (organization or each repository).

The deploy scripts on a runner never read `C:\Ritesh\workspace\repeato-data\keys`: in a workflow the keys come from the repository secrets (`toJSON(secrets)`), so the laptop runner behaves exactly like a GitHub machine.

## Linux VM install

1. Create a VM (Ubuntu 24.04, 2 vCPU, 4 GB RAM, 30 GB disk), no public inbound ports: the runner only connects out to GitHub.
2. Install Docker (CI's MySQL service needs it), `pwsh`, `git`, and add the user to the `docker` group.
3. New runner → Linux x64 at the organization, then:

   ```bash
   mkdir actions-runner && cd actions-runner
   curl -o runner.tar.gz -L https://github.com/actions/runner/releases/download/v2.338.2/actions-runner-linux-x64-2.338.2.tar.gz
   tar xzf runner.tar.gz && rm runner.tar.gz
   ./config.sh --url https://github.com/repeato-in --token <TOKEN> --name repeato-vm --labels repeato-vm --work _work --unattended
   sudo ./svc.sh install && sudo ./svc.sh start
   ```
4. Set `CI_RUNNER` = `repeato-vm` and, if wanted, `DEPLOY_RUNNER` = `repeato-vm`.

## Security

- **Private repositories only.** A self-hosted runner runs whatever a workflow says. The four app repositories are private, so only people with write access can start jobs. `repeato.infra` is **public**: never let it use the runner. Its own CI (`check.yml`) is pinned to `ubuntu-latest`, and the organization's runner group must keep "Allow public repositories" **off** (Settings → Actions → Runner groups → Default).
- **Forks.** Keep "Require approval for all outside collaborators" for fork pull requests (Settings → Actions → General). Pull requests from forks get no secrets anyway.
- **The laptop holds the production keys** in `repeato-data\keys`. A job on the laptop runs as your Windows user and could read them. Only people you trust should have write access to the app repositories while the laptop runner is registered. The VM avoids this: it holds no keys.
- Run the runner as an ordinary user, not an administrator.
- Remove a runner: Settings → Actions → Runners → the runner → Remove, then `./config.cmd remove --token <TOKEN>` on the machine.
