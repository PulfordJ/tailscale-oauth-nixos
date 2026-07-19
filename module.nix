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

    advertiseRoutes = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Subnets to advertise as Tailscale subnet routes";
    };
  };

  config = mkIf cfg.enable {
    # Enable tailscale service
    services.tailscale.enable = true;

    # Configure tailscaled to start after routing service
    systemd.services.tailscaled = {
      after = [ "network-online.target" ]
        ++ lib.optional (config.systemd.services ? tailscale-routing) "tailscale-routing.service";
      requires = [ "network-online.target" ];
    };

    # Create a oneshot job to authenticate to Tailscale using OAuth
    systemd.services.tailscale-autoconnect = {
      enable = true;
      description = "Automatic connection to Tailscale using OAuth";

      # Make sure tailscale is running and internet is reachable before connecting
      after = [ "network-online.target" "tailscale.service" ];
      wants = [ "network-online.target" "tailscale.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "10s";
        StartLimitIntervalSec = "120s";
        StartLimitBurst = 10;
      };

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
        OAUTH_RESPONSE=$(${curl}/bin/curl -s --fail-with-body -d "client_id=$CLIENT_ID" \
          -d "client_secret=$CLIENT_SECRET" \
          https://api.tailscale.com/api/v2/oauth/token 2>&1)
        CURL_EXIT=$?
        echo "curl exit=$CURL_EXIT response=$OAUTH_RESPONSE"
        if [ $CURL_EXIT -ne 0 ]; then
          echo "curl failed getting OAuth token (exit $CURL_EXIT)"
          exit 6
        fi

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

        AUTH_KEY_RESPONSE=$(${curl}/bin/curl -s --fail-with-body -X POST \
          -H "Authorization: Bearer $ACCESS_TOKEN" \
          -H "Content-Type: application/json" \
          -d "{\"capabilities\":{\"devices\":{\"create\":{\"reusable\":false,\"ephemeral\":true,\"preauthorized\":true,\"tags\":$TAGS_JSON}}},\"expirySeconds\":${toString cfg.authKeyExpirySeconds}}" \
          "https://api.tailscale.com/api/v2/tailnet/-/keys" 2>&1)
        CURL_EXIT=$?
        echo "curl exit=$CURL_EXIT response=$AUTH_KEY_RESPONSE"
        if [ $CURL_EXIT -ne 0 ]; then
          echo "curl failed generating auth key (exit $CURL_EXIT)"
          exit 1
        fi

        AUTH_KEY=$(echo "$AUTH_KEY_RESPONSE" | ${jq}/bin/jq -r '.key')

        if [ -z "$AUTH_KEY" ] || [ "$AUTH_KEY" = "null" ]; then
          echo "Failed to generate auth key"
          echo "Response: $AUTH_KEY_RESPONSE"
          exit 1
        fi

        echo "Successfully generated ephemeral auth key"

        # Authenticate with tailscale
        ${tailscale}/bin/tailscale up --authkey "$AUTH_KEY" ${optionalString cfg.advertiseExitNode "--advertise-exit-node"} ${optionalString (cfg.advertiseRoutes != []) "--advertise-routes=${concatStringsSep "," cfg.advertiseRoutes}"}
      '';
    };

    # tailscale-autoconnect only runs `tailscale up` on first auth (it exits
    # early once BackendState is "Running"), so advertised routes need to be
    # (re-)applied on every boot via `tailscale set` instead.
    systemd.services.tailscale-set-routes = mkIf (cfg.advertiseRoutes != []) {
      enable = true;
      description = "Ensure Tailscale advertised routes are set";

      after = [ "network-online.target" "tailscale.service" "tailscale-autoconnect.service" ];
      wants = [ "network-online.target" "tailscale.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "10s";
        StartLimitIntervalSec = "120s";
        StartLimitBurst = 10;
      };

      script = with pkgs; ''
        set -x

        # Wait for tailscaled to be authenticated and running before setting routes
        for i in $(seq 1 30); do
          status="$(${tailscale}/bin/tailscale status -json | ${jq}/bin/jq -r .BackendState)"
          [ "$status" = "Running" ] && break
          sleep 2
        done

        ${tailscale}/bin/tailscale set --advertise-routes=${concatStringsSep "," cfg.advertiseRoutes}
      '';
    };

    # Add tailscale0 to trusted firewall interfaces if requested
    networking.firewall.trustedInterfaces = mkIf cfg.trustFirewall [ "tailscale0" ];
  };
}
