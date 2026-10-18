//! The cleanup rule database.
//!
//! Every rule describes one known space hog on a developer Mac: where it lives,
//! how it comes back, and how dangerous it is to delete. Nothing here is ever
//! deleted without an explicit `--apply`, and the safety level of a rule is
//! what `clean --level` filters on.

const std = @import("std");

pub const Group = enum {
    containers,
    xcode,
    languages,
    apps,
    browsers,
    system,
    dev,

    pub fn label(self: Group) []const u8 {
        return switch (self) {
            .containers => "containers",
            .xcode => "xcode",
            .languages => "languages",
            .apps => "apps",
            .browsers => "browsers",
            .system => "system",
            .dev => "dev",
        };
    }

    pub fn fromName(name: []const u8) ?Group {
        inline for (std.meta.fields(Group)) |field| {
            const value: Group = @enumFromInt(field.value);
            if (std.ascii.eqlIgnoreCase(name, value.label())) return value;
        }
        return null;
    }
};

pub const Safety = enum(u8) {
    /// Pure junk. Deleting it cannot lose data.
    safe = 0,
    /// Caches and build output. Comes back automatically on the next run.
    recreatable = 1,
    /// Real data that has to be re-created manually: container images, VMs,
    /// device backups, installed toolchains.
    risky = 2,

    pub fn label(self: Safety) []const u8 {
        return switch (self) {
            .safe => "safe",
            .recreatable => "recreatable",
            .risky => "risky",
        };
    }

    pub fn description(self: Safety) []const u8 {
        return switch (self) {
            .safe => "pure junk, nothing is lost",
            .recreatable => "caches and build output, recreated on demand",
            .risky => "real data: images, VMs, backups or toolchains",
        };
    }

    pub fn fromName(name: []const u8) ?Safety {
        inline for (std.meta.fields(Safety)) |field| {
            const value: Safety = @enumFromInt(field.value);
            if (std.ascii.eqlIgnoreCase(name, value.label())) return value;
        }
        return null;
    }
};

pub const Kind = enum { path, command };

pub const Remove = enum {
    /// Delete the directory (or file) itself.
    tree,
    /// Empty the directory but keep it, since apps expect it to exist.
    contents,
    /// Delete a single file.
    file,
};

pub const Rule = struct {
    id: []const u8,
    title: []const u8,
    group: Group,
    safety: Safety,
    kind: Kind = .path,
    remove: Remove = .tree,
    /// Rule patterns, expanded by pathx.expand (`~` and `*` are supported).
    paths: []const []const u8 = &.{},
    /// Command to run for `.command` rules.
    argv: []const []const u8 = &.{},
    /// Optional path measured to report a size for a `.command` rule.
    probe: []const u8 = "",
    /// Deletion needs root; the tool only prints the command.
    needs_root: bool = false,
    /// What it is and how it comes back.
    why: []const u8 = "",
    /// Measured as "everything in the path that no other rule already claims".
    /// Used for umbrella rules such as ~/Library/Caches so that totals are not
    /// counted twice.
    remainder: bool = false,
};

/// The command line a rule would run, for display purposes.
pub fn commandLine(arena: std.mem.Allocator, rule: Rule) ![]const u8 {
    return std.mem.join(arena, " ", rule.argv);
}

pub const rules = [_]Rule{
    // ---------------------------------------------------------------- containers
    .{
        .id = "docker-desktop-vm",
        .title = "Docker Desktop VM disk",
        .group = .containers,
        .safety = .risky,
        .remove = .file,
        .paths = &.{"~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"},
        .why = "Grows forever and never shrinks. `docker system prune -a --volumes` reclaims layers inside it; deleting the file drops every image and container.",
    },
    .{
        .id = "docker-desktop-logs",
        .title = "Docker Desktop logs",
        .group = .containers,
        .safety = .safe,
        .paths = &.{"~/Library/Containers/com.docker.docker/Data/log"},
        .why = "VM and daemon logs.",
    },
    .{
        .id = "docker-prune",
        .title = "docker system prune -a --volumes",
        .group = .containers,
        .safety = .risky,
        .kind = .command,
        .argv = &.{ "docker", "system", "prune", "--all", "--volumes", "--force" },
        .why = "Drops unused images, containers, networks and volumes. Keeps Docker Desktop installed.",
    },
    .{
        .id = "orbstack-data",
        .title = "OrbStack machine data",
        .group = .containers,
        .safety = .risky,
        .paths = &.{"~/Library/Containers/com.orbstack.OrbStack/Data"},
        .why = "OrbStack VMs and container images.",
    },
    .{
        .id = "colima-vms",
        .title = "Colima VMs",
        .group = .containers,
        .safety = .risky,
        .paths = &.{"~/.colima"},
        .why = "Lima disk images used by `colima`. Run `colima delete` instead if you still want the tool configured.",
    },
    .{
        .id = "lima-vms",
        .title = "Lima instances",
        .group = .containers,
        .safety = .risky,
        .paths = &.{"~/.lima"},
        .why = "Backing disks for Lima VMs; also used by Docker on Colima and Rancher Desktop.",
    },
    .{
        .id = "podman-machines",
        .title = "Podman machines",
        .group = .containers,
        .safety = .risky,
        .paths = &.{"~/.local/share/containers/podman"},
        .why = "Podman VM disk images.",
    },
    .{
        .id = "minikube",
        .title = "minikube profiles and cache",
        .group = .containers,
        .safety = .risky,
        .paths = &.{"~/.minikube"},
        .why = "Every profile keeps its own VM plus a preload cache of images.",
    },
    .{
        .id = "kube-cache",
        .title = "kubectl discovery cache",
        .group = .containers,
        .safety = .safe,
        .paths = &.{ "~/.kube/cache", "~/.kube/http-cache" },
        .why = "API discovery documents; kubectl refetches them.",
    },
    .{
        .id = "helm-cache",
        .title = "Helm repository cache",
        .group = .containers,
        .safety = .safe,
        .paths = &.{"~/Library/Caches/helm"},
        .why = "Downloaded chart indexes.",
    },
    .{
        .id = "vagrant-boxes",
        .title = "Vagrant boxes",
        .group = .containers,
        .safety = .risky,
        .paths = &.{"~/.vagrant.d/boxes"},
        .why = "Downloaded base boxes, several GB each.",
    },
    .{
        .id = "virtualbox-vms",
        .title = "VirtualBox VMs",
        .group = .containers,
        .safety = .risky,
        .paths = &.{"~/VirtualBox VMs"},
        .why = "Virtual machine disks.",
    },
    .{
        .id = "parallels-vms",
        .title = "Parallels VMs",
        .group = .containers,
        .safety = .risky,
        .paths = &.{"~/Parallels"},
        .why = "Virtual machine disks.",
    },
    .{
        .id = "utm-vms",
        .title = "UTM virtual machines",
        .group = .containers,
        .safety = .risky,
        .paths = &.{"~/Library/Containers/com.utmapp.UTM/Data/Documents"},
        .why = "QEMU/Apple virtualisation disks.",
    },

    // --------------------------------------------------------------------- xcode
    .{
        .id = "xcode-derived-data",
        .title = "Xcode DerivedData",
        .group = .xcode,
        .safety = .recreatable,
        .remove = .contents,
        .paths = &.{"~/Library/Developer/Xcode/DerivedData"},
        .why = "Indexes and build products. Xcode rebuilds them.",
    },
    .{
        .id = "xcode-ios-device-support",
        .title = "iOS DeviceSupport symbols",
        .group = .xcode,
        .safety = .recreatable,
        .remove = .contents,
        .paths = &.{"~/Library/Developer/Xcode/iOS DeviceSupport"},
        .why = "Debug symbols copied from every iOS device/version; 3-6 GB each. Re-copied on next device run.",
    },
    .{
        .id = "xcode-watchos-device-support",
        .title = "watchOS DeviceSupport symbols",
        .group = .xcode,
        .safety = .recreatable,
        .remove = .contents,
        .paths = &.{"~/Library/Developer/Xcode/watchOS DeviceSupport"},
        .why = "Same as iOS DeviceSupport, for watches.",
    },
    .{
        .id = "xcode-tvos-device-support",
        .title = "tvOS DeviceSupport symbols",
        .group = .xcode,
        .safety = .recreatable,
        .remove = .contents,
        .paths = &.{"~/Library/Developer/Xcode/tvOS DeviceSupport"},
        .why = "Same as iOS DeviceSupport, for Apple TVs.",
    },
    .{
        .id = "xcode-archives",
        .title = "Xcode archives",
        .group = .xcode,
        .safety = .risky,
        .remove = .contents,
        .paths = &.{"~/Library/Developer/Xcode/Archives"},
        .why = "Shipped builds with their dSYMs. Needed to symbolicate crash reports; upload to the App Store once before deleting.",
    },
    .{
        .id = "xcode-previews",
        .title = "Xcode SwiftUI preview cache",
        .group = .xcode,
        .safety = .safe,
        .remove = .contents,
        .paths = &.{"~/Library/Developer/Xcode/UserData/Previews"},
        .why = "Preview simulator clones.",
    },
    .{
        .id = "xcode-documentation-cache",
        .title = "Xcode documentation cache",
        .group = .xcode,
        .safety = .safe,
        .remove = .contents,
        .paths = &.{"~/Library/Developer/Xcode/DocumentationCache"},
        .why = "Downloaded doc sets.",
    },
    .{
        .id = "simulator-caches",
        .title = "Simulator caches",
        .group = .xcode,
        .safety = .safe,
        .remove = .contents,
        .paths = &.{"~/Library/Developer/CoreSimulator/Caches"},
        .why = "Thumbnails and dyld caches.",
    },
    .{
        .id = "simulator-devices",
        .title = "Simulator devices",
        .group = .xcode,
        .safety = .risky,
        .remove = .contents,
        .paths = &.{"~/Library/Developer/CoreSimulator/Devices"},
        .why = "Every simulator and its app data. `xcrun simctl delete unavailable` only removes the stale ones.",
    },
    .{
        .id = "simulator-delete-unavailable",
        .title = "xcrun simctl delete unavailable",
        .group = .xcode,
        .safety = .recreatable,
        .kind = .command,
        .argv = &.{ "xcrun", "simctl", "delete", "unavailable" },
        .why = "Removes simulators whose runtime is gone. Much safer than deleting Devices.",
    },
    .{
        .id = "simulator-runtimes",
        .title = "Simulator runtime images",
        .group = .xcode,
        .safety = .risky,
        .remove = .contents,
        .paths = &.{"~/Library/Developer/CoreSimulator/Profiles/Runtimes"},
        .why = "iOS/watchOS/tvOS runtime downloads, ~7 GB each. Re-download from Xcode > Settings > Platforms.",
    },
    .{
        .id = "simulator-logs",
        .title = "Simulator logs",
        .group = .xcode,
        .safety = .safe,
        .remove = .contents,
        .paths = &.{"~/Library/Logs/CoreSimulator"},
        .why = "Runtime logs per simulator.",
    },
    .{
        .id = "swiftpm-cache",
        .title = "Swift Package Manager cache",
        .group = .xcode,
        .safety = .safe,
        .paths = &.{ "~/Library/Caches/org.swift.swiftpm", "~/Library/Caches/swift-build" },
        .why = "Fetched dependencies and build manifests.",
    },
    .{
        .id = "cocoapods-cache",
        .title = "CocoaPods cache",
        .group = .xcode,
        .safety = .safe,
        .paths = &.{"~/Library/Caches/CocoaPods"},
        .why = "Pod specs and downloads.",
    },
    .{
        .id = "carthage-cache",
        .title = "Carthage cache",
        .group = .xcode,
        .safety = .safe,
        .paths = &.{"~/Library/Caches/org.carthage.CarthageKit"},
        .why = "Framework build cache.",
    },
    .{
        .id = "ios-device-backups",
        .title = "iPhone/iPad backups",
        .group = .xcode,
        .safety = .risky,
        .remove = .contents,
        .paths = &.{"~/Library/Application Support/MobileSync/Backup"},
        .why = "Local device backups, often 20-100 GB. Check Finder > Devices before deleting.",
    },

    // ----------------------------------------------------------------- languages
    .{
        .id = "brew-cleanup",
        .title = "brew cleanup --prune=all",
        .group = .languages,
        .safety = .safe,
        .kind = .command,
        .argv = &.{ "brew", "cleanup", "--prune=all" },
        .probe = "~/Library/Caches/Homebrew",
        .why = "Removes old formula versions and downloads. The safest big win after a few years of upgrades.",
    },
    .{
        .id = "npm-cache",
        .title = "npm cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{"~/.npm/_cacache"},
        .why = "Tarballs of every package version you ever installed.",
    },
    .{
        .id = "yarn-cache",
        .title = "Yarn cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{ "~/Library/Caches/Yarn", "~/.cache/yarn" },
        .why = "Yarn offline mirror.",
    },
    .{
        .id = "pnpm-store",
        .title = "pnpm store",
        .group = .languages,
        .safety = .recreatable,
        .paths = &.{ "~/Library/pnpm/store", "~/.local/share/pnpm/store", "~/.pnpm-store" },
        .why = "Content addressed package store. Existing node_modules keep working, installs get slower.",
    },
    .{
        .id = "bun-cache",
        .title = "Bun install cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{"~/.bun/install/cache"},
        .why = "Downloaded packages.",
    },
    .{
        .id = "deno-cache",
        .title = "Deno cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{ "~/Library/Caches/deno", "~/.cache/deno" },
        .why = "Remote modules and compiled V8 code.",
    },
    .{
        .id = "node-gyp-cache",
        .title = "node-gyp headers",
        .group = .languages,
        .safety = .safe,
        .paths = &.{ "~/Library/Caches/node-gyp", "~/.node-gyp" },
        .why = "Node headers for every ABI version.",
    },
    .{
        .id = "electron-cache",
        .title = "Electron download cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{ "~/Library/Caches/electron", "~/.cache/electron" },
        .why = "Electron binaries downloaded by build scripts.",
    },
    .{
        .id = "playwright-browsers",
        .title = "Playwright browsers",
        .group = .languages,
        .safety = .recreatable,
        .paths = &.{"~/Library/Caches/ms-playwright"},
        .why = "Chromium/WebKit/Firefox builds; `npx playwright install` brings them back.",
    },
    .{
        .id = "puppeteer-browsers",
        .title = "Puppeteer browsers",
        .group = .languages,
        .safety = .recreatable,
        .paths = &.{"~/.cache/puppeteer"},
        .why = "Downloaded Chrome builds.",
    },
    .{
        .id = "cypress-cache",
        .title = "Cypress cache",
        .group = .languages,
        .safety = .recreatable,
        .paths = &.{"~/Library/Caches/Cypress"},
        .why = "Cypress binaries per version.",
    },
    .{
        .id = "go-build-cache",
        .title = "Go build cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{ "~/Library/Caches/go-build", "~/.cache/go-build" },
        .why = "Compiled package objects.",
    },
    .{
        .id = "go-mod-cache",
        .title = "Go module cache",
        .group = .languages,
        .safety = .recreatable,
        .paths = &.{"~/go/pkg/mod"},
        .why = "Every module version you ever built.",
    },
    .{
        .id = "cargo-registry-cache",
        .title = "Cargo crate downloads",
        .group = .languages,
        .safety = .safe,
        .paths = &.{"~/.cargo/registry/cache"},
        .why = "Archives of every crate version.",
    },
    .{
        .id = "cargo-registry-src",
        .title = "Cargo extracted crates",
        .group = .languages,
        .safety = .recreatable,
        .paths = &.{"~/.cargo/registry/src"},
        .why = "Unpacked crate sources.",
    },
    .{
        .id = "cargo-git-checkouts",
        .title = "Cargo git checkouts",
        .group = .languages,
        .safety = .recreatable,
        .paths = &.{"~/.cargo/git"},
        .why = "Clones of git dependencies.",
    },
    .{
        .id = "rustup-downloads",
        .title = "rustup downloads",
        .group = .languages,
        .safety = .safe,
        .paths = &.{ "~/.rustup/downloads", "~/.rustup/tmp" },
        .why = "Partial and finished toolchain tarballs.",
    },
    .{
        .id = "rustup-toolchains",
        .title = "rustup toolchains",
        .group = .languages,
        .safety = .risky,
        .paths = &.{"~/.rustup/toolchains"},
        .why = "Every installed toolchain, ~1.5 GB each. Reinstall with `rustup toolchain install`.",
    },
    .{
        .id = "zig-cache",
        .title = "Zig global cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{ "~/.cache/zig", "~/Library/Caches/zig" },
        .why = "Compilation artifacts for every project.",
    },
    .{
        .id = "gradle-caches",
        .title = "Gradle caches",
        .group = .languages,
        .safety = .safe,
        .paths = &.{"~/.gradle/caches"},
        .why = "Downloaded dependencies and transformed artifacts.",
    },
    .{
        .id = "gradle-daemon",
        .title = "Gradle daemon logs",
        .group = .languages,
        .safety = .safe,
        .paths = &.{"~/.gradle/daemon"},
        .why = "Daemon logs per Gradle version.",
    },
    .{
        .id = "gradle-wrapper-dists",
        .title = "Gradle wrapper distributions",
        .group = .languages,
        .safety = .recreatable,
        .paths = &.{"~/.gradle/wrapper/dists"},
        .why = "One full Gradle distribution per wrapper version.",
    },
    .{
        .id = "maven-repo",
        .title = "Maven local repository",
        .group = .languages,
        .safety = .risky,
        .paths = &.{"~/.m2/repository"},
        .why = "Every artifact ever resolved locally.",
    },
    .{
        .id = "ivy-cache",
        .title = "Ivy cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{"~/.ivy2/cache"},
        .why = "Legacy Scala/Java dependency cache.",
    },
    .{
        .id = "sbt-boot",
        .title = "sbt boot and resolution cache",
        .group = .languages,
        .safety = .recreatable,
        .paths = &.{ "~/.sbt/boot", "~/.sbt/1.0/dependency" },
        .why = "Launcher jars and resolved builds.",
    },
    .{
        .id = "android-avds",
        .title = "Android emulator images",
        .group = .languages,
        .safety = .risky,
        .paths = &.{"~/.android/avd"},
        .why = "Every AVD plus snapshots.",
    },
    .{
        .id = "android-system-images",
        .title = "Android SDK system images",
        .group = .languages,
        .safety = .risky,
        .paths = &.{"~/Library/Android/sdk/system-images"},
        .why = "Emulator system images, several GB per API level.",
    },
    .{
        .id = "android-studio-caches",
        .title = "Android Studio caches",
        .group = .languages,
        .safety = .safe,
        .paths = &.{"~/Library/Caches/Google/AndroidStudio*"},
        .why = "Indexes and logs per Android Studio version.",
    },
    .{
        .id = "pip-cache",
        .title = "pip cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{ "~/Library/Caches/pip", "~/.cache/pip" },
        .why = "Wheels and HTTP responses.",
    },
    .{
        .id = "uv-cache",
        .title = "uv cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{ "~/.cache/uv", "~/Library/Caches/uv" },
        .why = "uv's package cache.",
    },
    .{
        .id = "poetry-cache",
        .title = "Poetry cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{ "~/Library/Caches/pypoetry", "~/.cache/pypoetry" },
        .why = "Artifacts and virtualenvs built by Poetry.",
    },
    .{
        .id = "pre-commit-cache",
        .title = "pre-commit environments",
        .group = .languages,
        .safety = .safe,
        .paths = &.{"~/.cache/pre-commit"},
        .why = "One virtualenv per hook revision.",
    },
    .{
        .id = "conda-pkgs",
        .title = "Conda package cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{
            "~/.conda/pkgs",
            "~/miniconda3/pkgs",
            "~/anaconda3/pkgs",
            "~/opt/anaconda3/pkgs",
            "~/opt/miniconda3/pkgs",
        },
        .why = "Extracted package tarballs.",
    },
    .{
        .id = "gem-cache",
        .title = "RubyGems cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{ "~/.gem/ruby/*/cache", "~/.local/share/gem/ruby/*/cache" },
        .why = "Downloaded .gem files.",
    },
    .{
        .id = "bundler-cache",
        .title = "Bundler cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{"~/.bundle/cache"},
        .why = "Cached gems for bundler.",
    },
    .{
        .id = "pub-cache",
        .title = "Dart/Flutter pub cache",
        .group = .languages,
        .safety = .recreatable,
        .paths = &.{"~/.pub-cache"},
        .why = "Packages and git checkouts.",
    },
    .{
        .id = "hex-cache",
        .title = "Hex package cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{ "~/.hex/packages", "~/.mix/archives" },
        .why = "Elixir packages and Mix archives.",
    },
    .{
        .id = "stack-cache",
        .title = "Stack programs and indices",
        .group = .languages,
        .safety = .recreatable,
        .paths = &.{ "~/.stack/programs", "~/.stack/indices", "~/.stack/pantry" },
        .why = "GHC builds and package indices.",
    },
    .{
        .id = "cabal-packages",
        .title = "Cabal package cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{"~/.cabal/packages"},
        .why = "Downloaded Hackage tarballs.",
    },
    .{
        .id = "nuget-packages",
        .title = "NuGet global packages",
        .group = .languages,
        .safety = .recreatable,
        .paths = &.{"~/.nuget/packages"},
        .why = "Extracted packages shared by all .NET projects.",
    },
    .{
        .id = "nuget-http-cache",
        .title = "NuGet HTTP cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{"~/Library/Caches/NuGet"},
        .why = "HTTP responses.",
    },
    .{
        .id = "composer-cache",
        .title = "Composer cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{ "~/Library/Caches/composer", "~/.composer/cache", "~/.cache/composer" },
        .why = "PHP package archives.",
    },
    .{
        .id = "terraform-plugins",
        .title = "Terraform plugin cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{"~/.terraform.d/plugin-cache"},
        .why = "Provider binaries.",
    },
    .{
        .id = "julia-packages",
        .title = "Julia depot",
        .group = .languages,
        .safety = .recreatable,
        .paths = &.{ "~/.julia/packages", "~/.julia/compiled", "~/.julia/downloads" },
        .why = "Packages and compiled caches.",
    },
    .{
        .id = "vmodules-cache",
        .title = "V modules cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{"~/.vmodules/cache"},
        .why = "Compiled V modules.",
    },
    .{
        .id = "nim-cache",
        .title = "Nim cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{ "~/.cache/nim", "~/nimcache" },
        .why = "Generated C sources and objects.",
    },
    .{
        .id = "opam-downloads",
        .title = "opam download cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{"~/.opam/download-cache"},
        .why = "OCaml package archives.",
    },
    .{
        .id = "conan-cache",
        .title = "Conan cache",
        .group = .languages,
        .safety = .recreatable,
        .paths = &.{ "~/.conan2/p", "~/.conan/data" },
        .why = "Resolved C/C++ packages.",
    },
    .{
        .id = "asdf-downloads",
        .title = "asdf downloads",
        .group = .languages,
        .safety = .safe,
        .paths = &.{"~/.asdf/downloads"},
        .why = "Source and binary archives.",
    },
    .{
        .id = "mise-cache",
        .title = "mise cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{ "~/.cache/mise", "~/.local/share/mise/downloads" },
        .why = "Tool downloads and metadata.",
    },
    .{
        .id = "pyenv-cache",
        .title = "pyenv build cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{"~/.pyenv/cache"},
        .why = "Python tarballs.",
    },
    .{
        .id = "rbenv-cache",
        .title = "rbenv build cache",
        .group = .languages,
        .safety = .safe,
        .paths = &.{"~/.rbenv/cache"},
        .why = "Ruby tarballs.",
    },
    .{
        .id = "sdkman-archives",
        .title = "SDKMAN archives",
        .group = .languages,
        .safety = .safe,
        .paths = &.{ "~/.sdkman/archives", "~/.sdkman/tmp" },
        .why = "Downloaded JDK/Gradle/Maven archives.",
    },
    .{
        .id = "nix-gc",
        .title = "nix-collect-garbage -d",
        .group = .languages,
        .safety = .risky,
        .kind = .command,
        .argv = &.{ "nix-collect-garbage", "-d" },
        .why = "Removes every Nix store path not reachable from a current profile.",
    },

    // ---------------------------------------------------------------------- apps
    .{
        .id = "vscode-cache",
        .title = "VS Code caches",
        .group = .apps,
        .safety = .safe,
        .paths = &.{
            "~/Library/Application Support/Code/Cache",
            "~/Library/Application Support/Code/CachedData",
            "~/Library/Application Support/Code/CachedExtensionVSIXs",
            "~/Library/Application Support/Code/Code Cache",
            "~/Library/Application Support/Code/GPUCache",
            "~/Library/Application Support/Code/logs",
        },
        .why = "Extension VSIXs, renderer caches and logs.",
    },
    .{
        .id = "cursor-cache",
        .title = "Cursor caches",
        .group = .apps,
        .safety = .safe,
        .paths = &.{
            "~/Library/Application Support/Cursor/Cache",
            "~/Library/Application Support/Cursor/CachedData",
            "~/Library/Application Support/Cursor/CachedExtensionVSIXs",
            "~/Library/Application Support/Cursor/Code Cache",
            "~/Library/Application Support/Cursor/GPUCache",
            "~/Library/Application Support/Cursor/logs",
        },
        .why = "Same layout as VS Code.",
    },
    .{
        .id = "slack-cache",
        .title = "Slack caches",
        .group = .apps,
        .safety = .safe,
        .paths = &.{
            "~/Library/Application Support/Slack/Cache",
            "~/Library/Application Support/Slack/Code Cache",
            "~/Library/Application Support/Slack/GPUCache",
        },
        .why = "Electron caches; Slack re-downloads history.",
    },
    .{
        .id = "discord-cache",
        .title = "Discord caches",
        .group = .apps,
        .safety = .safe,
        .paths = &.{
            "~/Library/Application Support/discord/Cache",
            "~/Library/Application Support/discord/Code Cache",
            "~/Library/Application Support/discord/GPUCache",
        },
        .why = "Electron caches.",
    },
    .{
        .id = "spotify-cache",
        .title = "Spotify cache",
        .group = .apps,
        .safety = .safe,
        .remove = .contents,
        .paths = &.{"~/Library/Caches/com.spotify.client"},
        .why = "Streamed audio and artwork.",
    },
    .{
        .id = "dropbox-cache",
        .title = "Dropbox file cache",
        .group = .apps,
        .safety = .safe,
        .paths = &.{"~/Dropbox/.dropbox.cache"},
        .why = "Recently synced file copies.",
    },
    .{
        .id = "container-app-caches",
        .title = "Sandboxed app caches",
        .group = .apps,
        .safety = .recreatable,
        .remove = .contents,
        .paths = &.{"~/Library/Containers/*/Data/Library/Caches"},
        .why = "Cache folders inside app sandboxes.",
    },

    // ------------------------------------------------------------------ browsers
    .{
        .id = "chrome-cache",
        .title = "Chrome cache",
        .group = .browsers,
        .safety = .safe,
        .remove = .contents,
        .paths = &.{ "~/Library/Caches/Google/Chrome", "~/Library/Caches/Google/Chrome Canary" },
        .why = "Page and media cache per profile.",
    },
    .{
        .id = "safari-cache",
        .title = "Safari cache",
        .group = .browsers,
        .safety = .safe,
        .remove = .contents,
        .paths = &.{"~/Library/Caches/com.apple.Safari"},
        .why = "Web content cache.",
    },
    .{
        .id = "firefox-cache",
        .title = "Firefox cache",
        .group = .browsers,
        .safety = .safe,
        .remove = .contents,
        .paths = &.{"~/Library/Caches/Firefox"},
        .why = "Web content cache.",
    },
    .{
        .id = "other-browser-caches",
        .title = "Brave/Edge/Arc/Chromium caches",
        .group = .browsers,
        .safety = .safe,
        .remove = .contents,
        .paths = &.{
            "~/Library/Caches/BraveSoftware",
            "~/Library/Caches/com.microsoft.edgemac",
            "~/Library/Caches/Arc",
            "~/Library/Caches/Chromium",
            "~/Library/Caches/com.operasoftware.Opera",
        },
        .why = "Web content cache.",
    },

    // -------------------------------------------------------------------- system
    .{
        .id = "trash",
        .title = "Trash",
        .group = .system,
        .safety = .safe,
        .remove = .contents,
        .paths = &.{"~/.Trash"},
        .why = "Everything you dragged to the bin. Emptying the bin only frees space once you delete it.",
    },
    .{
        .id = "library-caches",
        .title = "~/Library/Caches",
        .group = .system,
        .safety = .recreatable,
        .remove = .contents,
        .paths = &.{"~/Library/Caches"},
        .remainder = true,
        .why = "Every app cache. Nothing is lost, apps rebuild what they need.",
    },
    .{
        .id = "library-logs",
        .title = "~/Library/Logs",
        .group = .system,
        .safety = .safe,
        .remove = .contents,
        .paths = &.{"~/Library/Logs"},
        .why = "Application and crash logs.",
    },
    .{
        .id = "saved-app-state",
        .title = "Saved application state",
        .group = .system,
        .safety = .safe,
        .remove = .contents,
        .paths = &.{"~/Library/Saved Application State"},
        .why = "Window restoration state.",
    },
    .{
        .id = "mail-downloads",
        .title = "Mail attachments",
        .group = .system,
        .safety = .safe,
        .remove = .contents,
        .paths = &.{"~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"},
        .why = "Attachments already saved out of Mail.",
    },
    .{
        .id = "time-machine-snapshots",
        .title = "Time Machine local snapshots",
        .group = .system,
        .safety = .risky,
        .kind = .command,
        .argv = &.{ "tmutil", "deletelocalsnapshots", "/" },
        .why = "Hourly APFS snapshots kept for 24h (longer when Time Machine cannot reach its disk). Often 10-50 GB and the reason macOS updates refuse to start. macOS recreates them.",
    },
    .{
        .id = "system-caches",
        .title = "/Library/Caches",
        .group = .system,
        .safety = .safe,
        .remove = .contents,
        .paths = &.{"/Library/Caches"},
        .needs_root = true,
        .why = "System wide app caches. Reported only; mac-cleaner does not delete system files.",
    },
    .{
        .id = "system-logs",
        .title = "/Library/Logs",
        .group = .system,
        .safety = .safe,
        .remove = .contents,
        .paths = &.{"/Library/Logs"},
        .needs_root = true,
        .why = "System logs and diagnostic reports. Reported only.",
    },
    .{
        .id = "system-updates",
        .title = "Staged macOS updates",
        .group = .system,
        .safety = .safe,
        .remove = .contents,
        .paths = &.{"/Library/Updates"},
        .needs_root = true,
        .why = "Update payloads already installed. Reported only.",
    },
    .{
        .id = "sleep-image",
        .title = "Hibernation image",
        .group = .system,
        .safety = .risky,
        .remove = .file,
        .paths = &.{"/private/var/vm/sleepimage"},
        .needs_root = true,
        .why = "RAM sized hibernation file (16-64 GB), owned by the system. Reported only; mac-cleaner does not delete system files.",
    },
    .{
        .id = "cores",
        .title = "/cores crash dumps",
        .group = .system,
        .safety = .safe,
        .remove = .contents,
        .paths = &.{"/cores"},
        .needs_root = true,
        .why = "Core dumps from crashed processes. Reported only.",
    },
    .{
        .id = "relocated-items",
        .title = "Relocated Items",
        .group = .system,
        .safety = .safe,
        .remove = .contents,
        .paths = &.{"/Users/Shared/Relocated Items"},
        .needs_root = true,
        .why = "Files macOS moved out of system locations during upgrades. Reported only.",
    },
};

pub fn find(id: []const u8) ?Rule {
    for (rules) |rule| {
        if (std.mem.eql(u8, rule.id, id)) return rule;
    }
    return null;
}

test "rule ids are unique" {
    for (rules, 0..) |rule, i| {
        for (rules[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, rule.id, other.id));
        }
    }
}

test "rules are well formed" {
    for (rules) |rule| {
        try std.testing.expect(rule.id.len > 0);
        try std.testing.expect(rule.title.len > 0);
        switch (rule.kind) {
            .path => try std.testing.expect(rule.paths.len > 0),
            .command => try std.testing.expect(rule.argv.len > 0),
        }
        if (rule.needs_root) try std.testing.expect(rule.kind == .path);
        for (rule.paths) |path| {
            try std.testing.expect(std.mem.startsWith(u8, path, "~/") or std.mem.startsWith(u8, path, "/"));
        }
    }
}

test "safety and group names round trip" {
    inline for (std.meta.fields(Safety)) |field| {
        const value: Safety = @enumFromInt(field.value);
        try std.testing.expectEqual(value, Safety.fromName(value.label()).?);
    }
    inline for (std.meta.fields(Group)) |field| {
        const value: Group = @enumFromInt(field.value);
        try std.testing.expectEqual(value, Group.fromName(value.label()).?);
    }
    try std.testing.expect(Safety.fromName("nope") == null);
}
