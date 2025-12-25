# Zigstarizer

My approach at coding very simple rasterizer in zig. Only software rendering with SDL backend (just modifying screen's pixels' values).
Work in progress, I am just trying to learn a bit about computer graphics.

Build pipeline also has a metaprogram that translates simple .obj file into zig file with exposed arrays of faces and vertices.

Tricks I learned so far:
- all the camera navigation
- incremental evaluation of edge function
- triangle bounding box

### How it looks so far
https://github.com/user-attachments/assets/9c356bde-8014-4363-b64b-08fd2b31e32b

To run the demo simply run (it will generate both asset code and run demo):
`zig build run` -> developed with zig version 0.15.2


