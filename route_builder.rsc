# Route Builder Script for MikroTik
# This script collects all possible gateways from routing table (including disabled and tunnel interfaces),
# checks availability of a target IP through them, and creates routes if accessible.

# Usage: 
# 1. Set the target IP you want to check
# 2. Run this script in MikroTik Terminal or as a scheduled script

:local targetIP "8.8.8.8" ; # Change this to the IP you want to check
:local routeDistance 1 ; # Distance for created routes
:local commentPrefix "ROUTE_BUILDER_TO_"

# Log start
:log info message=("Route Builder: Starting check for connectivity to " . $targetIP)

# Create array to store unique gateway-interface pairs
:local gatewayList [:toarray ""]
:local index 0

# Get all routes including disabled ones, extract gateway and interface information
:foreach r in=[/ip route find dont-require-connected=yes] do={
    :local gateway [/ip route get $r gateway]
    :local interface [/ip route get $r interface]
    :local disabled [/ip route get $r disabled]
    :local distance [/ip route get $r distance]
    
    # Skip if no gateway
    :if ([$gateway] != "") do={
        # Check if this gateway-interface pair already exists in our list
        :local found 0
        :for i from=0 to=($index - 1) do={
            :if ([:pick $gatewayList $i] = ($gateway . "|" . $interface)) do={
                :set found 1
            }
        }
        
        # Add to list if not found
        :if ($found = 0) do={
            :set ($gatewayList->$index) ($gateway . "|" . $interface)
            :set index ($index + 1)
            :log debug message=("Found gateway: " . $gateway . " via interface: " . $interface . " (disabled: " . $disabled . ")")
        }
    }
}

# Also check all interfaces for tunnel types that might not have explicit routes
:foreach i in=[/interface find] do={
    :local ifaceName [/interface get $i name]
    :local ifaceType [/interface get $i type]
    
    # Check for tunnel interfaces (gre, ipip, eoip, l2tp, pptp, sstp, ovpn, wireguard, etc.)
    :if ([:pick $ifaceType 0 3] = "gre" || [:pick $ifaceType 0 4] = "ipip" || [:pick $ifaceType 0 4] = "eoip" || \
         [:pick $ifaceType 0 4] = "l2tp" || [:pick $ifaceType 0 4] = "pptp" || [:pick $ifaceType 0 4] = "sstp" || \
         [:pick $ifaceType 0 4] = "ovpn" || [:pick $ifaceType 0 8] = "wireguard" || $ifaceType = "vlan" || \
         $ifaceType = "bridge" || $ifaceType = "bonding") do={
        
        # Check if this interface already has a gateway in our list
        :local found 0
        :for j from=0 to=($index - 1) do={
            :local entry [:pick $gatewayList $j]
            :if ([:find $entry ("|" . $ifaceName)] != nil) do={
                :set found 1
            }
        }
        
        # If not found, we can't add without a gateway, but log the tunnel interface
        :if ($found = 0) do={
            :log debug message=("Found tunnel/special interface without explicit gateway: " . $ifaceName . " (type: " . $ifaceType . ")")
        }
    }
}

:log info message=("Route Builder: Found " . $index . " unique gateway-interface combinations")

# Test connectivity through each gateway
:local routeCreated 0
:for i from=0 to=($index - 1) do={
    :local entry [:pick $gatewayList $i]
    :local pos [:find $entry "|"]
    :local gw [:pick $entry 0 $pos]
    :local iface [:pick $entry ($pos + 1) [:len $entry]]
    
    :log info message=("Testing connectivity to " . $targetIP . " via gateway " . $gw . " interface " . $iface)
    
    # Try to ping through this specific gateway and interface
    # We use src-address to force the path through the specific interface
    :local pingResult [/ping $targetIP count=3 interface=$iface gateway=$gw src-address=([/ip address get [/ip address find interface=$iface limit-to-interface=$iface] address] | :put [:pick $it 0 [:find $it "/"]]) as-value]
    
    # Alternative: simple ping with interface specification
    :local pingStatus [/ping $targetIP count=2 interface=$iface as-value]
    
    :if ([:tostr $pingStatus->"received"] > 0) do={
        :log info message=("SUCCESS: " . $targetIP . " is reachable via gateway " . $gw . " interface " . $iface . " (received: " . [:tostr $pingStatus->"received"] . ")")
        
        # Check if route already exists
        :local existingRoute [/ip route find where dst-address=($targetIP . "/32") and gateway=$gw and interface=$iface]
        
        :if ([:len $existingRoute] = 0) do={
            # Create new route
            /ip route add dst-address=($targetIP . "/32") gateway=$gw interface=$iface distance=$routeDistance comment=($commentPrefix . $targetIP)
            :log info message=("Route created: " . $targetIP . "/32 via " . $gw . " on " . $iface)
            :set routeCreated 1
        } else={
            :log info message=("Route already exists for " . $targetIP . " via " . $gw . " on " . $iface)
        }
        
        # Break after first successful route (optional - remove this line if you want multiple routes)
        # break
    } else={
        :log info message=("FAILED: " . $targetIP . " is NOT reachable via gateway " . $gw . " interface " . $iface)
    }
}

# Final summary
:if ($routeCreated = 1) do={
    :log info message=("Route Builder: Completed - at least one route was created for " . $targetIP)
} else={
    :log info message=("Route Builder: Completed - no new routes were created for " . $targetIP . " (either unreachable or routes already exist)")
}
