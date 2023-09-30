{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    stork = {
      url = "github:isc-projects/stork";
      flake = false;
    };
  };
  outputs = { self, nixpkgs, stork, ... }:
    let
      lib = nixpkgs.lib;
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;
    in
    {
      nixosModules.default = { lib, config, pkgs, ... }:
        let
          cfg = config.services.stork;
        in
        with lib; {
          options = {
            services.stork = {
              server = {
                enable = mkOption {
                  type = types.bool;
                  default = false;
                  description = lib.mdDoc ''
                    Whether to enable {command}`stork-server`.
                  '';
                };
                user = mkOption {
                  type = types.str;
                  default = "stork-server";
                  description = lib.mdDoc ''
                    User account under which stork-server runs.
                  '';
                };
                group = mkOption {
                  type = types.str;
                  default = "stork-server";
                  description = lib.mdDoc ''
                    Group under which stork-server runs.
                  '';
                };
                createLocalDB = mkOption {
                  type = types.bool;
                  default = true;
                  description = lib.mdDoc ''
                    Create local db.
                  '';
                };

                networkNamespace = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = lib.mdDoc ''
                    Network namespace that mullvad runs in.
                  '';
                };

                passwordFile = mkOption {
                  type = types.path;
                  default = "/run/keys/stork-dbpassword";
                  description = lib.mdDoc ''
                    A file containing the password corresponding to
                    database user.
                  '';
                };
              };
              agent = {
                enable = mkOption {
                  type = types.bool;
                  default = false;
                  description = lib.mdDoc ''
                    Whether to enable {command}`stork-agent`.
                  '';
                };
                networkNamespace = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = lib.mdDoc ''
                    Network namespace that mullvad runs in.
                  '';
                };
              };
            };
          };

          config = lib.mkMerge [
            (mkIf cfg.agent.enable {
              systemd.services.stork-agent = {
                description = "Stork Agent";
                wantedBy = [ "multi-user.target" ];
                environment = {
                  STORK_AGENT_SERVER_URL = "http://localhost:8080";
                  STORK_AGENT_PORT = "8081";
                  STORK_AGENT_HOST = "127.0.0.1";
                };
                serviceConfig = {
                  User = "stork-agent";
                  DynamicUser = true;
                  StateDirectory = "stork-agent";
                  WorkingDirectory = "/var/lib/stork-agent";
                  ExecStart = "${self.packages.${pkgs.system}.isc-stork}/bin/stork-agent";
                  NetworkNamespacePath = optionalString (cfg.agent.networkNamespace != null) "/var/run/netns/${cfg.agent.networkNamespace}";
                };
              };
            })
            (mkIf cfg.server.enable {
              systemd.services.stork-server = {
                description = "Stork Server";
                wantedBy = [ "multi-user.target" ];
                requires = [
                  "postgresql.service"
                ];
                after = [
                  "network.target"
                  "postgresql.service"
                ];
                environment = {
                  STORK_REST_STATIC_FILES_DIR = "${self.packages.${pkgs.system}.isc-stork-ui}/stork";
                  STORK_DATABASE_NAME = "stork";
                  STORK_DATABASE_USER_NAME = "stork-server";
                  STORK_DATABASE_HOST = "/run/postgresql";
                };
                serviceConfig = {
                  User = cfg.server.user;
                  Group = cfg.server.group;
                  ExecStart = "${self.packages.${pkgs.system}.isc-stork}/bin/stork-server";
                  NetworkNamespacePath = optionalString (cfg.server.networkNamespace != null) "/var/run/netns/${cfg.server.networkNamespace}";
                };

                preStart = ''
                  ${config.services.postgresql.package}/bin/psql -d stork -U stork-server -c "SELECT 1 from pg_extension WHERE extname='pgcrypto';" | grep -q 1 || ${config.services.postgresql.package}/bin/psql -d stork -U stork-server -c "CREATE EXTENSION pgcrypto;"
                '';
                #  ${self.packages.${pkgs.system}.isc-stork}/bin/stork-tool db-create --db-name stork --db-user stork-server --db-password $(cat ${cfg.server.passwordFile})

              };

              services.postgresql = mkIf cfg.server.createLocalDB {
                enable = true;
                ensureUsers = [{
                  name = "stork-server";
                  ensurePermissions = {
                    "DATABASE stork" = "ALL PRIVILEGES";
                  };
                }];
                ensureDatabases = [ "stork" ];
              };
              users.users.stork-server = {
                description = "stork-server user";
                group = "stork-server";
                extraGroups = [ "keys" ];
                uid = config.ids.uids.stork-server;
              };
              ids.gids.stork-server = 355;
              ids.uids.stork-server = 355;
              users.groups.stork-server.gid = config.ids.gids.stork-server;
            })
          ];
        };
      packages = forAllSystems
        (system:
          let
            pkgs = import nixpkgs {
              inherit system;
            };
          in
          rec {
            yamlinc = pkgs.buildNpmPackage {
              name = "yamlinc";
              src = pkgs.fetchFromGitHub {
                owner = "javanile";
                repo = "yamlinc";
                rev = "c6538686db9ca3d3f794566e311d1c2e0c7ce9bb";
                hash = "sha256-wbMyY7NQiJpU9D7ReK2rTuFSpo2prJ0FqloxihBfuCQ=";
              };
              npmDepsHash = "sha256-v387sN48CpueKHU4vfmpSVNY4GOpfh5LADkEg3LZAiI=";
              dontBuild = true;
              dontCheck = true;
            };
            stork-code-gen = pkgs.buildGoModule
              {
                name = "stork-code-gen";
                src = stork + /backend;
                nativeBuildInputs = with pkgs; [
                  protobuf
                  protoc-gen-go
                  protoc-gen-go-grpc
                  go-swagger
                  yamlinc
                ];

                vendorHash = "sha256-UbROFLXB2/xUW1WXnhgYta6TI5pwXOr8za1suqEX3SE=";

                subPackages = [
                  "cmd/stork-code-gen"
                ];

                preBuild = ''
                  yamlinc -o swagger.yaml ${stork}/api/swagger.in.yaml
                  swagger generate server -m server/gen/models -s server/gen/restapi --exclude-main --name "Stork" --regenerate-configureapi --spec swagger.yaml --template stratoscale
                  cd api
                  protoc --proto_path=. --go_out=. --go-grpc_out=. agent.proto
                  cd ..
                '';
              };
            isc-stork-ui = pkgs.buildNpmPackage (
              let
                mansalva = builtins.fetchurl {
                  url = "https://github.com/google/fonts/raw/18679c2264c45f843833a4caea23d81806682126/ofl/mansalva/Mansalva-Regular.ttf";
                  sha256 = "12pvv9qcylvs8chqnkw3ifxz5n5mbnkfim8658lgsr53y2aa4g31";
                };
              in
              {
                name = "isc-stork-ui";
                src = stork + /webui;
                npmDepsHash = "sha256-TApBWDhbSxDLWaYUUAo0j7aLYVrwTR7cdU94AKmobv4=";
                nativeBuildInputs = with pkgs; [
                  yamlinc
                  openapi-generator-cli
                ];

                postPatch = ''
                  cp ${mansalva} src/assets/Mansalva-Regular.ttf
                  sed -i 's!.*https://fonts.googleapis.com/.*!<style>@font-face {\nfont-family: 'Mansalva';\nsrc: url('assets/Mansalva-Regular.ttf') format('truetype'); \n} </style>!g' src/index.html
                '';

                preBuild = ''
                  yamlinc -o swagger.yaml ${stork}/api/swagger.in.yaml
                  openapi-generator-cli generate -i swagger.yaml -g typescript-angular -o src/app/backend --additional-properties snapshot=true,ngVersion=10.1.5,modelPropertyNaming=camelCase
                  ${stork-code-gen}/bin/stork-code-gen std-option-defs --input ${stork}/codegen/std_dhcpv4_option_def.json --output src/app/std-dhcpv4-option-defs.ts --template src/app/std-dhcpv4-option-defs.ts.template
                  ${stork-code-gen}/bin/stork-code-gen std-option-defs --input ${stork}/codegen/std_dhcpv6_option_def.json --output src/app/std-dhcpv6-option-defs.ts --template src/app/std-dhcpv6-option-defs.ts.template
                '';

                installPhase = ''
                  cp -r dist $out
                '';
                npmBuildFlags = [ "--" "--configuration" "production" ];

              }
            );
            isc-stork = pkgs.buildGoModule {
              name = "isc-stork";
              src = stork + /backend;
              nativeBuildInputs = with pkgs; [
                protobuf
                protoc-gen-go
                protoc-gen-go-grpc
                go-swagger
                yamlinc
              ];

              vendorHash = "sha256-UbROFLXB2/xUW1WXnhgYta6TI5pwXOr8za1suqEX3SE=";

              subPackages = [
                "cmd/stork-agent"
                "cmd/stork-server"
                "cmd/stork-tool"
              ];

              preBuild = ''
                yamlinc -o swagger.yaml ${stork}/api/swagger.in.yaml
                swagger generate server -m server/gen/models -s server/gen/restapi --exclude-main --name "Stork" --regenerate-configureapi --spec swagger.yaml --template stratoscale
                cd api
                protoc --proto_path=. --go_out=. --go-grpc_out=. agent.proto
                cd ..
                ${stork-code-gen}/bin/stork-code-gen std-option-defs --input ${stork}/codegen/std_dhcpv4_option_def.json --output appcfg/kea/stdoptiondef4.go --template appcfg/kea/stdoptiondef4.go.template
                ${stork-code-gen}/bin/stork-code-gen std-option-defs --input ${stork}/codegen/std_dhcpv6_option_def.json --output appcfg/kea/stdoptiondef6.go --template appcfg/kea/stdoptiondef6.go.template
              '';

              doCheck = false;
            };
          });
      apps = forAllSystems
        (system:
          let
            pkgs = import nixpkgs {
              inherit system;
            };
          in
          {
            server = {
              type = "app";
              program = toString (pkgs.writers.writeBash "run-server" ''
                export STORK_REST_STATIC_FILES_DIR=${self.packages.${system}.isc-stork-ui}/stork 
                ${self.packages.${system}.isc-stork}/bin/stork-server
              '');
            };
          });
    };
}
