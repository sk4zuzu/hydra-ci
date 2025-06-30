#!/usr/bin/env bash

((!DETACHED)) && DETACHED=1 exec setsid --fork "$SHELL" "$0" "$@"

set -eu -o pipefail

: "${CONTEXT_PATH:=/dev/sr0}"

source <(isoinfo -i "$CONTEXT_PATH" -R -x /context.sh)

: "${HYDRA_HOST:=http://$ETH0_IP:3000}"
: "${HYDRA_USER:=asd}"
: "${HYDRA_PASSWORD:=asd}"
: "${HYDRA_PROJECT_ID:=hydra-ci}"
: "${HYDRA_FLAKE_URL:=https://github.com/sk4zuzu/hydra-ci.git}"
: "${HYDRA_BASE:=/var/tmp/$HYDRA_PROJECT_ID}"
: "${HYDRA_JOBS:=test1 test2}"

install -o 0 -g 0 -m u=rw,go=r /dev/fd/0 /etc/nixos/configuration.nix.d/01-hostname.nix <<NIX
{ ... }: { networking.hostName = "$SET_HOSTNAME"; }
NIX

install -o 0 -g 0 -m u=rw,go=r /dev/fd/0 /etc/nixos/configuration.nix.d/02-hydra.nix <<NIX
{ pkgs, ... }: {
  nixpkgs.overlays = [
    (final: prev: {
      hydra = prev.hydra.overrideAttrs (old:
        let
          hydra-qm-patch = pkgs.writeText "hydra-qm.patch" ''
            diff --git a/src/hydra-queue-runner/queue-monitor.cc b/src/hydra-queue-runner/queue-monitor.cc
            index 0785be6f..9c304a22 100644
            --- a/src/hydra-queue-runner/queue-monitor.cc
            +++ b/src/hydra-queue-runner/queue-monitor.cc
            @@ -57,7 +57,7 @@ void State::queueMonitorLoop(Connection & conn)
                     /* Sleep until we get notification from the database about an
                        event. */
                     if (done && !quit) {
            -            conn.await_notification();
            +            conn.await_notification(5*60, 0);
                         nrQueueWakeups++;
                     } else
                         conn.get_notifs();
          '';
        in { patches = (old.patches or []) ++ [hydra-qm-patch]; }
      );
    })
  ];
  nix = {
    settings = {
      download-buffer-size = 524288000;
      experimental-features = "nix-command flakes";
      sandbox = false;
      trusted-users = ["root"];
    };
    buildMachines = [{
      hostName = "localhost";
      protocol = null;
      system = "x86_64-linux";
      supportedFeatures = ["kvm" "nixos-test" "big-parallel" "benchmark"];
      maxJobs = 1;
      speedFactor = 1;
    }];
    gc = {
      automatic = true;
      dates = "weekly";
    };
  };
  environment.systemPackages = with pkgs; [
    libargon2
  ];
  services.hydra = {
    enable = true;
    hydraURL = "$HYDRA_HOST";
    notificationSender = "hydra@localhost";
    buildMachinesFiles = [ "/etc/nix/machines" ];
    useSubstitutes = true;
  };
}
NIX

install -o 0 -g 0 -m u=rw,go=r /dev/fd/0 /etc/nixos/configuration.nix.d/03-timers.nix <<NIX
{ pkgs, ... }: {
  systemd = {
    timers."hydra-ci-touch" = {
      after = [ "hydra-evaluator.service" ];
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Mon..Fri 23:00";
        Unit = "hydra-ci-touch.service";
      };
    };
    services."hydra-ci-touch" = {
      after = [ "hydra-evaluator.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "122";
        WorkingDirectory = "$HYDRA_BASE";
      };
      path = with pkgs; [ coreutils git nix ];
      script = ''
        for JOB in $HYDRA_JOBS; do
          (cd \$JOB/ && nix flake update --override-input entropy file+file://<(date --utc))
        done
      '';
    };
  };
}
NIX

nixos-rebuild switch

SALT="$(LC_ALL=C tr -dc '[:alnum:]' < /dev/urandom | head -c 16)" || true
HASH="$(tr -d \\n <<< "$HYDRA_PASSWORD" | argon2 "$SALT" -id -t 3 -k 262144 -p 1 -l 16 -e)"

RETRY=60
while ! sudo -u hydra hydra-create-user "$HYDRA_USER" --password-hash "$HASH" --role admin; do
    ((--RETRY))
    sleep 5
done

RETRY=60
while ! curl -fsSL -H 'Accept: application/json' "$HYDRA_HOST/"; do
    ((--RETRY))
    sleep 5
done

for JOB in $HYDRA_JOBS; do install -o 122 -g 122 -m u=rwx,go=rx -d "$HYDRA_BASE/"{,"$JOB/"}; done
for JOB in $HYDRA_JOBS; do install -o 122 -g 122 -m u=rw,go=r /dev/fd/0 "/var/tmp/hydra-ci/$JOB/flake.nix" <<NIX
{
  inputs = {
    entropy = {
      url = "file+file:///dev/null";
      flake = false;
    };
    hydra-ci = {
      url = "git+$HYDRA_FLAKE_URL";
      inputs.entropy.follows = "entropy";
    };
  };
  outputs = { hydra-ci, ... }: {
    checks.x86_64-linux.hydra-ci-$JOB = hydra-ci.checks.x86_64-linux.hydra-ci-$JOB;
  };
}
NIX
done

for JOB in $HYDRA_JOBS; do cat <<JSON
{
  "hydra-ci-$JOB": {
    "enabled": 1,
    "hidden": false,
    "description": "hydra-ci-$JOB",
    "flake": "path:$HYDRA_BASE/$JOB",
    "checkinterval": 30,
    "schedulingshares": 100,
    "enableemail": false,
    "emailoverride": "",
    "keepnr": 1,
    "type": 1
  }
}
JSON
done | jq -rs add | install -o 122 -g 122 -m u=rw,go=r /dev/fd/0 "$HYDRA_BASE/spec.json"

read -r -d "#\n" LOGIN_JSON <<JSON
{
  "username": "$HYDRA_USER",
  "password": "$HYDRA_PASSWORD"
}#
JSON

read -r -d "#\n" PROJECT_JSON <<JSON
{
  "displayname": "$HYDRA_PROJECT_ID",
  "enabled": true,
  "hidden": false,
  "declarative": {
    "type": "path",
    "file": "spec.json",
    "value": "$HYDRA_BASE"
  }
}#
JSON

curl --fail-early --show-error \
--silent \
-X POST --referer "$HYDRA_HOST" "$HYDRA_HOST/login" \
--cookie-jar ~/hydra-session \
--json "$LOGIN_JSON" \
-: \
--silent \
-X PUT --referer "$HYDRA_HOST/login" "$HYDRA_HOST/project/$HYDRA_PROJECT_ID" \
--cookie ~/hydra-session \
--json "$PROJECT_JSON"

rm -f ~/hydra-session

sync
