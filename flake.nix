{
  inputs = {
    entropy = {
      url = "file+file:///dev/null";
      flake = false;
    };
  };
  outputs = { self, nixpkgs, ... }@inputs:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      addCheck = { name, rc, ... }: pkgs.testers.runNixOSTest {
        name = name;
        nodes = {
          m1 = { ... }: {
            nix.settings.sandbox = false;
            networking.useDHCP = false;
            networking.interfaces.eth0.useDHCP = true;
            virtualisation.cores = 1;
            virtualisation.memorySize = 1 * 1024;
            virtualisation.diskSize = 1 * 1024;
          };
        };
        testScript = ''
          print("${inputs.entropy}")
          print("${./spec.json}")
          m1.wait_for_unit("multi-user.target")
          print(m1.succeed("exit ${rc}"))
        '';
      };
    in {
      checks.x86_64-linux = {
        hydra-ci-test1 = addCheck {
          name = "test1";
          rc = "1";
        };
        hydra-ci-test2 = addCheck {
          name = "test2";
          rc = "0";
        };
      };
    };
}
