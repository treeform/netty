--path:"../src"

import distros
when detectOs(MacOSX):
    # On macOS localhost writes take longer, so sleep in strategic places
    # to make it like Windows and Linux.
    --define:"magicTestSleep"
