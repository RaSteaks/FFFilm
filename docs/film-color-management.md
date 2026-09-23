# Color management for film slicing

Current scope (2026-09-23): import, geometric slicing and export only. The earlier curve/editing-space/negative-grading workflow has been removed. No tone adjustments, inversion, mask normalization or automatic film-stock conversion is applied, including when opening a project that previously stored those adjustments.

## Retained pipeline

1. Decode full-resolution ImageIO data and orientation. Embedded profiles take precedence over fallback assignment. An untagged import requires explicitly selecting the scanner software's known output space or supplying a matching RGB ICC; the assigned ICC bytes are retained in the project. Linear encoding alone does not establish sRGB primaries.
2. Core Image uses extended-linear sRGB with 32-bit floating-point working buffers. This is an internal processing space, not a bounded 8-bit sRGB conversion. Crop and rotate without applying grading filters.
3. Preview uses tagged extended-linear half-float RGBA, allowing native display color management to convert to the monitor. Actual display accuracy still depends on its profile/calibration.
4. Export converts to and embeds the selected destination profile: 16-bit Adobe RGB TIFF or 8-bit sRGB JPEG. Those are output encodings, not the scan's native profile; out-of-gamut output colors can be limited by the destination gamut.

Whole-strip previews/exports position rotated crops in their original slots; individual exports retain the complete rotated bounds. Old grading keys are ignored when decoding projects and dropped when saving. Existing standalone preset files are not accessed or removed.

## Basis and limits

- [ICC scanner/profile guidance](https://www.color.org/findprofile/): the input profile must describe the stored scan numbers, whether those are scanner RGB or a scanner-software-converted output space.
- [Adobe: profile assignment versus conversion](https://helpx.adobe.com/ie/photoshop/desktop/adjust-color/color-profiles/change-color-profile-for-documents.html): assignment specifies how existing values are interpreted; conversion transforms values into another space.
- [Apple: Core Image working color space](https://developer.apple.com/documentation/coreimage/cicontextoption/workingcolorspace): inputs and outputs are color-matched around the working space. [Extended RGB spaces](https://developer.apple.com/documentation/uikit/determining-color-values-with-color-spaces) can represent values beyond nominal gamut bounds.
- [Kodak sensitometry](https://www.kodak.com/content/products-brochures/Film/Basic-Photographic-Sensitometry-Workbook.pdf) and the [ICC FAQ](https://www.color.org/faqs.pdf) distinguish film density/negative conversion from input-device color management. Slicing deliberately leaves this grading work to other software.

The test suite checks untagged/custom ICC assignment and persistence, rejection of invalid ICC, wide-gamut preview preservation, and unchanged source colors through crop/rotation and TIFF/JPEG output despite obsolete grading fields in an old project. Real `007.fff` full-image decoding was established separately; its actual input profile has not been verified, so calibrated color accuracy is not claimed.
