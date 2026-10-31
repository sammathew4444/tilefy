#pragma once

/// Creates a virtual display through CoreGraphics' private CGVirtualDisplay API, so the real-window
/// tests can exercise two displays on a CI machine that has one. Returns NULL on failure.
void *TilefyCreateVirtualDisplay(unsigned int width, unsigned int height);

/// Removes the display, the same as unplugging it.
void TilefyDestroyVirtualDisplay(void *display);
