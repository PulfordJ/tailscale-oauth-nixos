# Tailscale OAuth NixOS Module

A NixOS module that provides automatic Tailscale authentication using OAuth client credentials. This eliminates the need for static auth keys that can expire, providing a more robust and maintainable authentication solution.

## Features

- OAuth-based authentication with dynamically generated ephemeral keys
- Automatic reconnection on boot
- Configurable device tags
- Optional exit node advertisement
- Firewall configuration
- No manual intervention required after initial setup

## How It Works

1. The module checks if Tailscale is already authenticated
2. If not, it uses OAuth client credentials to obtain an access token
3. The access token is used to generate an ephemeral, pre-authorized auth key
4. The device authenticates using the generated key
5. Optionally advertises as an exit node

## Prerequisites

You need to create OAuth credentials in your Tailscale admin console:

1. Go to [Tailscale Admin Console](https://login.tailscale.com/admin/settings/oauth)
2. Generate OAuth Client credentials
3. Configure the required scopes (see below)
4. Note down the Client ID and Client Secret
5. Create appropriate tags in your Tailscale ACL (e.g., `tag:media-center`)

### Required OAuth Scopes

When creating your OAuth client credentials, configure the following scopes under **Settings → OAuth Clients → [Your Client] → Scopes**:

- **Devices → Core**: Select **Read & Write** (or just Write)
  - This gives your machine the permission it needs to register itself and modify its own device properties on your Tailnet.

- **Keys → Auth Keys**: Select **Read & Write** (or just Write)
  - Because you are passing an OAuth client secret directly to the Tailscale daemon, the daemon uses this permission behind the scenes to silently generate a short-lived standard auth key for the initial login.

Once configured, use the resulting **Client ID** and **Client Secret** in the module configuration as shown in the Usage section below.

## Usage

### Using Flakes

Add this flake as an input to your system configuration:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    tailscale-oauth.url = "git+file:///path/to/tailscale-oauth-nixos";
  };

  outputs = { self, nixpkgs, tailscale-oauth }: {
    nixosConfigurations.yourhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        tailscale-oauth.nixosModules.default
        {
          services.tailscale-oauth = {
            enable = true;
            clientId = "your-client-id";
            clientSecret = "your-client-secret";
            tags = [ "tag:media-center" ];
            advertiseExitNode = true;
          };
        }
      ];
    };
  };
}
```

### Direct Import

You can also import the module directly:

```nix
{ config, pkgs, ... }:

{
  imports = [
    /path/to/tailscale-oauth-nixos/module.nix
  ];

  services.tailscale-oauth = {
    enable = true;
    clientId = "your-client-id";
    clientSecret = "your-client-secret";
    tags = [ "tag:media-center" ];
    advertiseExitNode = true;
  };
}
```

## Configuration Options

### `services.tailscale-oauth.enable`
- Type: `boolean`
- Default: `false`
- Description: Enable the Tailscale OAuth authentication module

### `services.tailscale-oauth.clientId`
- Type: `string`
- Required: Yes
- Description: Your Tailscale OAuth client ID

### `services.tailscale-oauth.clientSecret`
- Type: `string`
- Required: Yes
- Description: Your Tailscale OAuth client secret

### `services.tailscale-oauth.tags`
- Type: `list of strings`
- Default: `[ "tag:media-center" ]`
- Description: Tailscale ACL tags to apply to this device

### `services.tailscale-oauth.advertiseExitNode`
- Type: `boolean`
- Default: `false`
- Description: Whether to advertise this device as a Tailscale exit node

### `services.tailscale-oauth.authKeyExpirySeconds`
- Type: `integer`
- Default: `3600`
- Description: Expiry time in seconds for generated ephemeral auth keys

### `services.tailscale-oauth.trustFirewall`
- Type: `boolean`
- Default: `true`
- Description: Whether to add `tailscale0` to trusted firewall interfaces

## Security Considerations

- The OAuth client secret is stored in the Nix store, which is world-readable
- For production use, consider using a secrets management solution like:
  - [agenix](https://github.com/ryantm/agenix)
  - [sops-nix](https://github.com/Mic92/sops-nix)
  - [NixOS secrets management](https://nixos.wiki/wiki/Comparison_of_secret_managing_schemes)

Example with agenix:

```nix
services.tailscale-oauth = {
  enable = true;
  clientId = "your-client-id";
  clientSecret = config.age.secrets.tailscale-client-secret.path;
  # ... other options
};
```

## Troubleshooting

Check the service status:
```bash
systemctl status tailscale-autoconnect
```

View service logs:
```bash
journalctl -u tailscale-autoconnect -f
```

Check Tailscale status:
```bash
tailscale status
```

## License

MIT

## Contributing

Contributions welcome! Please open an issue or PR.
