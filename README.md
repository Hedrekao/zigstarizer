# Zigstarizer

My approach at coding very simple rasterizer in zig. Only software rendering with SDL backend (just modifying screen's pixels' values).
Work in progress, I am just trying to learn a bit about computer graphics.

Build pipeline also has a metaprogram that translates simple .obj file into zig file with exposed arrays of faces and vertices.

Tricks I learned so far:
- all the camera navigation
- incremental evaluation of edge function
- triangle bounding box
- perspective correct interpolation
- backface culling

### How it looks so far
#### The christmas demo
https://github.com/user-attachments/assets/9c356bde-8014-4363-b64b-08fd2b31e32b

#### The COW demo
https://github.com/user-attachments/assets/7ffa1224-aeef-48fe-8306-c6e295a066d6

You can either run obj2zig to manually translate obj file to zig one using

`zig build obj2zig -- <input_path> <output_path>`

To run one of the demos simply run (it will generate automatically required asset code and run demo):

`zig build run -- <name of model> <--rainbow>`, fx `zig build run -- cow --rainbow`

--rainbow flag will result in all triangles having one vertex red, one green, one blue

(developed with zig version 0.15.2)


