# Tortoise WoW One-Click Compiler

Run a private [Turtle WoW](https://turtle-wow.org/) server. This stack uses [Shyalya/tortoise-wow](https://github.com/Shyalya/tortoise-wow) with playerbots.

The server work come from this video:

**[Tortoise WoW / playerbots Docker setup (YouTube)](https://youtu.be/BFJes1sIi6c)**

This repository includes a bundle of scripts used for compiling a working server and transferring your characters and data from my previous iterations(Native Windows server or Docker build)

## What you need

- Git(auto-installs, but if fails - install manually)
- CMake(auto-installs, but if fails - install manually)
- VS Community or Build Tools with Desktop Development with C++(auto-installs, but if fails - install manually)
- A Turtle WoW **1.18.1** client (**build 7272**)
- Client data folders: `dbc`, `maps`, `vmaps`, `mmaps`
- Several GB of free disk space

The repo does not include client data. You extract that data from your game client. The video shows how to get them.

## Quick start

### 1. Get the repo files

```bash
git clone https://github.com/kasperfriend/tortoise-oneclick-compiler
cd tortoise-oneclick-compiler
```

### 2. Assuming you have requirements

```bash
compile-tortoise-wow.bat
```
It will run database before compiling - that's fine, don't worry, it will compile the whole server next, don't close database until the server finishes building

The script clones the server source AND fetches its Git submodule (`src/modules/Eluna`, the Lua scripting engine) - CMake refuses to configure without it, so if you ever clone the source by hand, run `git submodule update --init --recursive` inside it too.

### 3.1 (optional) Extract client data

Put all extractors into game client folder and run: 1) mapextractor 2) vmapextractor 3) vmap_assembler 4) MoveMapGen(this is the longest, may take a lot of time!)

### 3.2 Add client data

Put the extracted folders(dbc, maps, vmaps and mmaps) directly into server folder, near mangosd.exe

### 4. Edit configs(important)

By default, configs will feature dev settings, which may cause lag and instability and will actually crash mangosd. I have included recommended conf files for both mangosd and aiplayerbot, you can compare them, tweak how you like it and replace default ones, but it's recommended to do before first launch!

You will need to manually create folders data, logs, honor and pdump or replace lines 12, 16, 20, 24 in mangosd.conf to be equal "." to avoid crashing mangosd

### 5. Create a game account and promote it

Inside mangosd.exe console type: account create username password, and to promote type: account set gmlevel username 4 -1

Change credentials if needed, and DON'T WORRY if the stream of data interrupts you - that's fine, continue typing and don't try to retype, it will still accept the right command

### 6. Connect with the client

Edit `realmlist.wtf` in your Turtle WoW client:

```text
set realmlist 127.0.0.1
```

### 7. Start the server

You can easily start the server with these steps: 1) Run start-database.bat in DB folder 2) Run realmd.exe in server folder 3) Run mangosd.exe in server folder

It will apply a LONG list of SQL migrations on first launch, which may take around 20 minutes. After same SQL INSERT lines stop streaming and change into different fast moving commands - you may try to create account. Also you may hear a Windows beep sound when it's ready.


## Troubleshooting

| Problem | What to do |
|---|---|
| `CMake Error at CMakeLists.txt:50: Eluna submodule is missing` | The source's Lua submodule wasn't fetched. Run `git submodule update --init --recursive` inside the `source` folder, then re-run `compile-tortoise-wow.bat` (current versions of the script do this for you). If GitHub is blocked on your network, set `$BuildEluna = $false` near the top of `compile-tortoise-wow.ps1` and re-run - you get a server without Lua scripting |
| `CMake configure failed` (other) | Scroll up to the first `CMake Error`. No `Found ACE headers:` line means the vcpkg ACE install failed; a lua.org download failure means Eluna's Lua runtime couldn't be fetched during configure |
| Bots feel slower than the tuned config suggests / `ElunaErrors.log` mentions parallel object updates | Eluna (Lua) is enabled by default, and one Lua state cannot be shared across threads, so the core forces continent maps back to single-threaded object/visibility updates. If you don't use Lua scripts, set `Eluna.Enabled = 0` in `mangosd.conf` and restart - `RECOMMENDED_mangosd.conf` has no Eluna lines, so add it there too if you use that file |
| Login fails / unknown account | Wait for `World server is up and running`, then create the account again |
| Account create does nothing | mangosd is still starting; wait and retry |
| Realm list is empty or offline | Check that `realmd` and `mangosd` are up: `docker compose ps` |
| Client hangs after you pick the realm | Set `REALM_ADDRESS` to an IP the client can reach; world port is `8090` |
| Empty world / no NPCs | First database import failed; check `docker compose logs db-init` |
| No bots | Use `TAG=playerbots` and `AI_PLAYERBOT_ENABLED=1` |
| Client crash: interface corrupt | Use the published image from this project; do not strip Turtle addons |

## Credits

- Setup walkthrough: [YouTube video](https://www.youtube.com/watch?v=CNgkHs3btNE)
- Server source: [Shyalya/tortoise-wow](https://github.com/Shyalya/tortoise-wow)
- Install notes: [INSTALL-LINUX.md](https://github.com/Shyalya/tortoise-wow/blob/playerbots-integration-gh/INSTALL-LINUX.md)

Server code stays under the upstream project license. This repository only provides the Docker packaging.
