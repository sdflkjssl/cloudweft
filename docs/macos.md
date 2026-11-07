# CloudWeft for macOS

CloudWeft integrates AList-backed Quark and Baidu storage with Finder via Apple's File Provider framework. The host app, File Provider extension and local AList bridge form one installation.

## Install

Requires macOS with File Provider support and Apple Command Line Tools (Swift compiler and code signing). From the repository root:

```bash
bash scripts/install-macos.sh
```

The installer checks required dependencies, builds the app and extension, registers the File Provider, starts the local AList and bridge services and verifies their status. Configure storage providers through the local AList management UI:

```bash
bash scripts/open-alist.sh
```

For Baidu, the guided setup is `scripts/setup-baidu.command`. Mount a new AList storage by using its supported driver and mount path in `macos/Shared/providers.json`; confirm the bridge recognizes it.

The local services run at `127.0.0.1:5244` (AList) and `127.0.0.1:8081` (bridge). They do not require publicly accessible cloud credentials in project source files.

## Compatibility with existing installations

**CloudWeft is the public product name.** The macOS installer deliberately retains the existing `/Applications/Plinth.app` bundle path, `com.quarkpan.plinth` identifiers, app group, File Provider domain IDs and `~/Library/CloudStorage/Plinth-*` directory identities. These are legacy internal compatibility identifiers: renaming them would risk disconnecting already registered File Provider domains and their local files. The displayed app and extension names are CloudWeft when newly built.

Do not manually remove or rename the installed app, old CloudStorage folders or File Provider domains to change branding. An upgrade uses the original bundle location and preserves already mounted data.

The File Provider implementation builds on [plinth](https://github.com/ytomasch/plinth) (MIT); see [third-party notices](third-party-notices.md).

## Diagnostics

```bash
bash scripts/plinth-doctor.sh
```

Refresh an existing File Provider domain without removing or re-registering it:

```bash
/Applications/Plinth.app/Contents/MacOS/Plinth --refresh-cloud quark
```

Additional directory arguments can target existing folders relative to the chosen storage root. For example, `--refresh-cloud quark Documents Projects` signals those folders after refreshing the root. Use the provider IDs from `macos/Shared/providers.json`. The `Plinth.app` executable and bundle identifiers are retained for compatibility, while the displayed product name is CloudWeft.

This diagnostic filename is retained for compatibility. A healthy setup should show AList, bridge and registered File Provider domains. For troubleshooting, check the local bridge logs, AList admin UI and Finder extension permission before reinstalling or deleting any cached cloud data.
