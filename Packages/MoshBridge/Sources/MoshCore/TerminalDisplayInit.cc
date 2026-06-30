#include "terminaldisplay.h"

Terminal::Display::Display(bool use_environment)
  : has_ech(true),
    has_bce(true),
    has_title(true),
    smcup(nullptr),
    rmcup(nullptr)
{
  (void)use_environment;
}
