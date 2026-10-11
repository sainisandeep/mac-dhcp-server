# DHCP Server for macOS

A small menu-bar app that turns a Mac into a DHCP server. Pick a network interface, choose an address pool, press Start, and every device on that network gets an IP address from your Mac.

It is meant for networks that have no DHCP server of their own: a lab bench, a switch full of test devices, a direct Ethernet link to a camera or a Raspberry Pi.

> **Run only one DHCP server per network.** If a router is already handing out addresses on the network you select, turn its DHCP off first. Two servers on one network give devices conflicting answers.

## Features

- Choose the interface to serve (Ethernet, Wi-Fi, USB adapters, bridges)
- Set the first address, pool size and lease time; the app suggests a pool that fits the interface's subnet
- Optional router and DNS servers sent to each device
- Reserved addresses: a given MAC address always receives the same IP
- Devices tab listing every lease, and an Activity tab logging each offer and assignment
- Runs in the background from the menu bar, with optional open-at-login and auto-start
- Leases are remembered across restarts
- Checks for an existing DHCP server on the network, on demand and automatically before starting
- No admin password needed

## Download

Requires macOS 13 or later, on Apple silicon or Intel.

1. Download `DHCP-Server.dmg` from the [latest release](https://github.com/sainisandeep/mac-dhcp-server/releases/latest).
2. Open it and drag **DHCP Server** to **Applications**.
3. Open the app. macOS will refuse the first time, because the app is not notarised by Apple. Go to System Settings › Privacy & Security, scroll down, and click **Open Anyway** next to the DHCP Server message.

You only need to do step 3 once.

## Build from source

You need the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
```

This produces `build/DHCP Server.app`. Open it from Finder or with:

```bash
open "build/DHCP Server.app"
```

To package it as a disk image for sharing:

```bash
./build.sh dmg
```

## Usage

1. **Give the Mac a manual IP address on the interface.** In System Settings › Network, set the interface to a manual address such as `192.168.10.1` with mask `255.255.255.0`. The app will not start on an interface that has no address or only a self-assigned `169.254.x.x` one.
2. **Select the interface** in the Setup tab.
3. **Adjust the pool** (first address, size, lease time). Fill in the router and DNS servers if the network has internet access; leave them blank otherwise.
4. **Press Start.** The app first spends about three seconds checking whether another DHCP server is already on the network, and asks before continuing if it finds one. The first time, macOS asks for Local Network permission. Allow it, or replies cannot be sent.
5. **Close the window** to leave the server running. The menu bar icon starts and stops the server, reopens the window, and quits the app.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| "Another DHCP server on this Mac is already using port 67" | macOS Internet Sharing (or another DHCP server) is running. Turn it off. |
| Start button is disabled | The message beside it says what to fix, usually a missing manual IP or a pool that does not fit the subnet. |
| Activity shows "Could not send a reply" | Local Network permission was denied. Enable DHCP Server in System Settings › Privacy & Security › Local Network. |
| Devices get no address | Check that they are on the selected interface and that no firewall is blocking incoming connections for the app. |
| "Open at login" does not stick | Move the app to `/Applications` and switch the toggle on again. |

## Limitations

- IPv4 only
- One interface and one subnet at a time; requests forwarded by DHCP relays are ignored
- Replies to devices that do not yet have an address are sent by broadcast
- Sends subnet mask, broadcast address, router, DNS and lease times; no other DHCP options (no PXE boot, domain name, NTP, etc.)

## Project layout

```
Sources/Core/       DHCP packet format, address allocation, socket handling, interface discovery
Sources/App/        SwiftUI window, menu bar item, settings storage
Sources/SelfTest/   Checks for the allocation logic (no network access)
Resources/          Info.plist for the app bundle
build.sh            Compiles with swiftc and assembles the .app
```

Run the logic checks with:

```bash
./build.sh test
```

Settings are stored in the app's preferences (`local.dhcpserver.app`); leases are stored in `~/Library/Application Support/DHCP Server/leases.json`.

## Contributing

Improvements are welcome.

- **Found a bug or have an idea?** Open an issue describing what you expected and what happened, including your macOS version and the Activity log if relevant.
- **Want to change the code?** Fork the repository, make your change on a branch, and open a pull request. Run `./build.sh test` first, and add a check to `Sources/SelfTest/main.swift` when you change how addresses are allocated.

Please test on an isolated network, not one other people depend on.

## License

MIT. See [LICENSE](LICENSE).
