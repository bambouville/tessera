#include "ProcessContext.h"
#include "Scope.h"
#include <iostream>

// Synthetic diagnostic driver. Never built into or invoked by the app.
// Only fixed error codes leave this driver, no captured environment values.
int main(int argc, char** argv) {
    try {
        tessera::contextHello(argc == 2 ? argv[1] : "");
        if (argc == 2) tessera::scopedRuntime(argv[1], true);
        std::cout << "ok\n";
    }
    catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
