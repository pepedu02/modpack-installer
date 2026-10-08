# Modpack updater

This project provides a small Windows updater for a versioned modpack archive.
It reads a remote manifest, checks the local archive with SHA-256, and
downloads the latest archive only when it is missing or does not match.

The archive is downloaded into a `download` folder next to the updater files:

```text
modpack installer\
├── download\
├── app\
│   ├── update-modpack.ps1
│   └── updater-config.json
├── update-modpack.bat
└── README.md
```

The updater does not extract or install the archive. It downloads to a
temporary file first and moves it into place only after its SHA-256 hash
matches the manifest.

## Distribution

Give players the updater folder containing:

```text
update-modpack.bat
app\
    update-modpack.ps1
    updater-config.json
```

The `download` folder is created automatically. The README is optional for
players and is not required for the updater to work.

## Maintainer setup

1. Host the versioned archive and a JSON manifest at stable HTTPS URLs.
2. Ensure both files can be downloaded without an interactive sign-in.
3. Put the manifest URL in `app\updater-config.json`.
4. Set the manifest's current version, archive filename, archive URL, and
   SHA-256 hash.
5. Distribute the updater folder.

The batch file does not contain release-specific information and should not
need to change between releases.

## Creating a SHA-256 hash

Use PowerShell to calculate the archive hash:

```powershell
Get-FileHash .\<archive-name>.zip -Algorithm SHA256
```

Copy the resulting hash into the manifest's `sha256` property. The manifest
must contain the exact hash of the hosted archive.

## Releasing a new version

1. Create a new versioned archive.
2. Calculate its SHA-256 hash.
3. Upload it to the hosting provider.
4. Update the existing manifest with the new version, filename, URL, and hash.
5. Keep the manifest URL unchanged.

Players can then run the same batch file to receive the new archive.

## Running it

Double-click `update-modpack.bat`. If the archive is already present in
`download` and its hash matches, nothing is downloaded. If it is missing or
different, the latest archive is downloaded and verified.

After a successful run, the `download` folder opens automatically and the
terminal closes. If something fails, the terminal stays open so the error can
be read. The archive is not placed in the normal Windows Downloads folder.
