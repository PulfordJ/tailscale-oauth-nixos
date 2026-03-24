{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.tailscale-oauth;
in {
  options.services.tailscale-oauth = {
    enable = mkEnableOption "Tailscale OAuth-based authentication";

    clientId = mkOption {
      type = types.str;
      description = "Tailscale OAuth client ID";
    };

    clientSecret = mkOption {
      type = types.str;
      description = "Tailscale OAuth client secret";
    };

    tags = mkOption {
      type = types.listOf types.str;
      default = [ "tag:media-center" ];
      description = "Tailscale tags to apply to this device";
    };

    advertiseExitNode = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to advertise this device as a Tailscale exit node";
    };

    authKeyExpirySeconds = mkOption {
      type = types.int;
      default = 3600;
      description = "Expiry time in seconds for generated ephemeral auth keys";
    };

    trustFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to add tailscale0 to trusted firewall interfaces";
    };
  };

  config = mkIf cfg.enable {
    # Enable tailscale service
    services.tailscale.enable = true;

    # Configure tailscaled to start after routing service
    systemd.services.tailscaled = {
      after = mkIf (config.systemd.services ? tailscale-routing) [ "tailscale-routing.service" ];
      requires = [ "network-online.target" ];
    };

    # Create a oneshot job to authenticate to Tailscale using OAuth
    systemd.services.tailscale-autoconnect = {
      enable = true;
      description = "Automatic connection to Tailscale using OAuth";

      # Make sure tailscale is running before trying to connect
      after = [ "network-pre.target" "tailscale.service" ];
      wants = [ "network-pre.target" "tailscale.service" ];
      wantedBy = [ "multi-user.target" ];

      # Set this service as a oneshot job
      serviceConfig.Type = "oneshot";

      # Shell script to handle OAuth authentication
      script = with pkgs; ''
        set -x  # Enable debug output

        # Wait for tailscaled to settle
        sleep 2

        # Check if we are already authenticated to tailscale
        status="$(${tailscale}/bin/tailscale status -json | ${jq}/bin/jq -r .BackendState)"
        if [ $status = "Running" ]; then
          exit 0
        fi

        # Tailscale OAuth credentials
        CLIENT_ID="${cfg.clientId}"
        CLIENT_SECRET="${cfg.clientSecret}"

        # Get OAuth access token
        echo "Getting OAuth access token..."
        OAUTH_RESPONSE=$(${curl}/bin/curl -s -d "client_id=$CLIENT_ID" \
          -d "client_secret=$CLIENT_SECRET" \
          https://api.tailscale.com/api/v2/oauth/token)

        ACCESS_TOKEN=$(echo "$OAUTH_RESPONSE" | ${jq}/bin/jq -r '.access_token')

        if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
          echo "Failed to get OAuth access token"
          echo "Response: $OAUTH_RESPONSE"
          exit 1
        fi

        echo "OAuth access token obtained successfully"

        # Generate ephemeral auth key using OAuth token
        # Using "-" as tailnet means "use the tailnet associated with this OAuth token"
        # Tags are required when using OAuth client credentials
        echo "Generating ephemeral auth key..."

        TAGS_JSON=$(echo '${builtins.toJSON cfg.tags}' | ${jq}/bin/jq -c '.')

        AUTH_KEY_RESPONSE=$(${curl}/bin/curl -s -X POST \
          -H "Authorization: Bearer $ACCESS_TOKEN" \
          -H "Content-Type: application/json" \
          -d "{\"capabilities\":{\"devices\":{\"create\":{\"reusable\":false,\"ephemeral\":true,\"preauthorized\":true,\"tags\":$TAGS_JSON}}},\"expirySeconds\":${toString cfg.authKeyExpirySeconds}}" \
          "https://api.tailscale.com/api/v2/tailnet/-/keys")

        AUTH_KEY=$(echo "$AUTH_KEY_RESPONSE" | ${jq}/bin/jq -r '.key')

        if [ -z "$AUTH_KEY" ] || [ "$AUTH_KEY" = "null" ]; then
          echo "Failed to generate auth key"
          echo "Response: $AUTH_KEY_RESPONSE"
          exit 1
        fi

        echo "Successfully generated ephemeral auth key"

        # Authenticate with tailscale
        ${tailscale}/bin/tailscale up --authkey "$AUTH_KEY" ${optionalString cfg.advertiseExitNode "--advertise-exit-node"}
      '';
    };

    # Add tailscale0 to trusted firewall interfaces if requested
    networking.firewall.trustedInterfaces = mkIf cfg.trustFirewall [ "tailscale0" ];
  };
}
