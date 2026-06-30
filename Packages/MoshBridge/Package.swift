// swift-tools-version: 5.10
import PackageDescription

// Upstream libprotobuf-lite source set from protobuf v21.12.
// The three mosh schemas all declare `option optimize_for = LITE_RUNTIME;`,
// so the full reflection/runtime graph is unnecessary.
let protobufSources: [String] = [
    "protobuf/src/google/protobuf/any_lite.cc",
    "protobuf/src/google/protobuf/arena.cc",
    "protobuf/src/google/protobuf/arenastring.cc",
    "protobuf/src/google/protobuf/arenaz_sampler.cc",
    "protobuf/src/google/protobuf/extension_set.cc",
    "protobuf/src/google/protobuf/generated_enum_util.cc",
    "protobuf/src/google/protobuf/generated_message_tctable_lite.cc",
    "protobuf/src/google/protobuf/generated_message_util.cc",
    "protobuf/src/google/protobuf/implicit_weak_message.cc",
    "protobuf/src/google/protobuf/inlined_string_field.cc",
    "protobuf/src/google/protobuf/io/coded_stream.cc",
    "protobuf/src/google/protobuf/io/io_win32.cc",
    "protobuf/src/google/protobuf/io/strtod.cc",
    "protobuf/src/google/protobuf/io/zero_copy_stream.cc",
    "protobuf/src/google/protobuf/io/zero_copy_stream_impl.cc",
    "protobuf/src/google/protobuf/io/zero_copy_stream_impl_lite.cc",
    "protobuf/src/google/protobuf/map.cc",
    "protobuf/src/google/protobuf/message_lite.cc",
    "protobuf/src/google/protobuf/parse_context.cc",
    "protobuf/src/google/protobuf/repeated_field.cc",
    "protobuf/src/google/protobuf/repeated_ptr_field.cc",
    "protobuf/src/google/protobuf/stubs/bytestream.cc",
    "protobuf/src/google/protobuf/stubs/common.cc",
    "protobuf/src/google/protobuf/stubs/int128.cc",
    "protobuf/src/google/protobuf/stubs/status.cc",
    "protobuf/src/google/protobuf/stubs/statusor.cc",
    "protobuf/src/google/protobuf/stubs/stringpiece.cc",
    "protobuf/src/google/protobuf/stubs/stringprintf.cc",
    "protobuf/src/google/protobuf/stubs/structurally_valid.cc",
    "protobuf/src/google/protobuf/stubs/strutil.cc",
    "protobuf/src/google/protobuf/stubs/time.cc",
    "protobuf/src/google/protobuf/wire_format_lite.cc",
]

// Mosh core subset for step 5. We intentionally omit frontend binaries and the
// terminfo constructor in terminaldisplayinit.cc; a local iOS-safe constructor
// shim under Sources/MoshCore/ replaces that piece.
let moshSources: [String] = [
    "mosh/src/crypto/base64.cc",
    "mosh/src/crypto/crypto.cc",
    "mosh/src/crypto/ocb_internal.cc",
    "mosh/src/frontend/terminaloverlay.cc",
    "mosh/src/network/compressor.cc",
    "mosh/src/network/network.cc",
    "mosh/src/network/transportfragment.cc",
    "mosh/src/statesync/completeterminal.cc",
    "mosh/src/statesync/user.cc",
    "mosh/src/terminal/parser.cc",
    "mosh/src/terminal/parseraction.cc",
    "mosh/src/terminal/parserstate.cc",
    "mosh/src/terminal/terminal.cc",
    "mosh/src/terminal/terminaldispatcher.cc",
    "mosh/src/terminal/terminaldisplay.cc",
    "mosh/src/terminal/terminalframebuffer.cc",
    "mosh/src/terminal/terminalfunctions.cc",
    "mosh/src/terminal/terminaluserinput.cc",
    "mosh/src/util/timestamp.cc",
]

let package = Package(
    name: "MoshBridge",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "MoshBridge", targets: ["MoshBridge"]),
    ],
    targets: [
        .target(
            name: "Protobuf",
            // Rooted at `Vendor/` so both the submodule (`protobuf/`) and our
            // own empty `ProtobufNoPublic/` live within the target path, keeping
            // the submodule working tree pristine. publicHeadersPath points at
            // the empty dir so NOTHING from protobuf leaks onto dependents'
            // include paths — Foundation's `<time.h>` would otherwise resolve
            // to protobuf's `stubs/time.h` and wreck libc++. Consumers reach
            // protobuf headers via their own explicit headerSearchPath.
            path: "Vendor",
            exclude: ["mosh", "MoshConfig", "MoshNoPublic"],
            sources: protobufSources,
            // Apple's third-party-SDK privacy rules list Protocol Buffers, so
            // ship a privacy manifest with the vendored runtime. SPM copies it
            // into a MoshBridge_Protobuf resource bundle inside the app.
            resources: [.copy("ProtobufPrivacy/PrivacyInfo.xcprivacy")],
            publicHeadersPath: "ProtobufNoPublic",
            cxxSettings: [
                .headerSearchPath("protobuf/src"),
                .define("HAVE_PTHREAD", to: "1"),
                .define("GOOGLE_PROTOBUF_NO_GENERIC_SERVICES", to: "1"),
                // map.h's hash-seed would otherwise call mach_absolute_time()
                // on Apple platforms — a required-reason API (SystemBootTime).
                // No .proto here uses map<> today, but this keeps a future map
                // field from silently referencing the symbol. (The app's
                // privacy manifest declares SystemBootTime 35F9.1 regardless,
                // for mosh's timestamp.cc.)
                .define("GOOGLE_PROTOBUF_NO_RDTSC", to: "1"),
                .unsafeFlags(["-fexceptions", "-frtti", "-Wno-everything"]),
            ]
        ),
        .target(
            name: "Mosh",
            dependencies: ["Protobuf"],
            // Same path-inside-Vendor trick as Protobuf. The submodule stays
            // pristine; our MoshConfig/config.h and MoshNoPublic/ sit next to
            // it. `#include "config.h"` from mosh sources resolves via the
            // `MoshConfig` headerSearchPath.
            path: "Vendor",
            exclude: ["protobuf", "ProtobufNoPublic", "ProtobufPrivacy"],
            sources: moshSources,
            publicHeadersPath: "MoshNoPublic",
            cxxSettings: [
                .headerSearchPath("MoshConfig"),
                .headerSearchPath("protobuf/src"),
                .headerSearchPath("../Sources/MoshCore/generated"),
                .headerSearchPath("mosh/src/crypto"),
                .headerSearchPath("mosh/src/network"),
                .headerSearchPath("mosh/src/statesync"),
                .headerSearchPath("mosh/src/terminal"),
                .headerSearchPath("mosh/src/util"),
                .headerSearchPath("mosh/src"),
                .define("HAVE_CONFIG_H", to: "1"),
                .unsafeFlags(["-fexceptions", "-frtti", "-Wno-everything"]),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
            ]
        ),
        .target(
            name: "MoshCore",
            dependencies: ["Protobuf", "Mosh"],
            path: "Sources/MoshCore",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("."),
                .headerSearchPath("generated"),
                .headerSearchPath("../../Vendor/protobuf/src"),
                .headerSearchPath("../../Vendor/MoshConfig"),
                .headerSearchPath("../../Vendor/mosh/src/crypto"),
                .headerSearchPath("../../Vendor/mosh/src/frontend"),
                .headerSearchPath("../../Vendor/mosh/src/network"),
                .headerSearchPath("../../Vendor/mosh/src/statesync"),
                .headerSearchPath("../../Vendor/mosh/src/terminal"),
                .headerSearchPath("../../Vendor/mosh/src/util"),
                .headerSearchPath("../../Vendor/mosh/src"),
                .unsafeFlags(["-fexceptions", "-frtti", "-Wno-everything"]),
            ]
        ),
        .target(
            name: "MoshBridge",
            dependencies: ["MoshCore"],
            path: "Sources/MoshBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("."),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
