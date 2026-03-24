{
  description = "NixOS module for Tailscale OAuth-based authentication";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
    nixosModules.default = import ./module.nix;
    nixosModules.tailscale-oauth = import ./module.nix;
  };
}
