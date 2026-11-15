# Audio CD support

Audio CD access uses macOS-mounted audio-track files and the volume's `.TOC.plist`; Macamp does not read raw sectors or install a drive plugin. Choose a mounted disc in **Local Files → Audio CD** when macOS sandboxing requires explicit volume access. The listing uses TOC track numbers and durations. Mixed-mode discs show only the audio tracks described in the first session; a disc without readable TOC/audio files reports an error.

Selected tracks can be played immediately, appended to the shared playlist, or extracted to a user-selected folder as AIFF or M4A. M4A uses AVFoundation's first-party Apple M4A export preset. Extraction runs one track at a time, reports file-level progress, supports cancellation, and keeps tracks completed before cancellation. Successful output is added to the Local Files library and uses the existing decoded local playback graph.

Validation performed: TOC parsing is covered with a mounted-volume fixture, including a mixed-mode session. Build and software tests do not validate optical-drive hardware, macOS's mounted-track representation, drive permissions, or signed sandbox access on a physical Mac; supported drive models and that physical workflow have not been verified in this environment.
