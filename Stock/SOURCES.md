# Stock backgrounds

The backgrounds FastBG ships with. All five are public domain, made by US federal agencies. Four came from
Wikimedia Commons and one from the Fish and Wildlife Service's video library, and `scripts/make-stock.sh` rebuilds
them from the originals. Each is cut to a loop and encoded as HEVC Main 10 at 1920x1080, with no audio.

| File | What it is | Source | Made into |
|---|---|---|---|
| `aurora.mp4` | Aurora australis from the International Space Station | NASA's Scientific Visualization Studio, [SVS 31281](https://commons.wikimedia.org/wiki/File:Aurora_Australis_as_seen_from_ISS_(SVS31281_-_1080p25).webm) | 14 s from 9 s in, the timestamp cropped off, 25 fps |
| `canyon.mp4` | Clouds rolling over the Grand Canyon, a time-lapse | Grand Canyon National Park, [NPS B-roll](https://commons.wikimedia.org/wiki/File:B-roll_Video_-_Time-lapse_of_Clouds_over_the_Canyon_-_November_20,_2025_(55087231001).webm) | 14 s from 4 s in |
| `lava.mp4` | Kīlauea's lava lake at dusk, a time-lapse | Hawaiʻi Volcanoes National Park, [NPS](https://commons.wikimedia.org/wiki/File:HAVO_20230607_timeplapse_LAVA_LAKE_VIDEO_J_Wei_(52958939258).webm) | 14 s from 6 s in |
| `salmon.mp4` | A school of salmon holding in a river under sunbeams, Togiak National Wildlife Refuge, Alaska | US Fish and Wildlife Service, National Conservation Training Center, [HD B-roll: Underwater Fish](https://fws.rev.vbrick.com/#/videos/515b2b3d-0f70-4acc-bbbc-265ead755caa) | 12 s from 183.6 s in, the dark corners cropped off, 29.97 fps |
| `earth.mp4` | The whole Earth turning, clouds and city lights | NASA's Scientific Visualization Studio, [SVS 5570](https://commons.wikimedia.org/wiki/File:Spinning_Earth_with_clouds,_atmosphere,_and_night_lights_(SVS5570).webm) | One turn at 4x speed, the globe moved to the right third |

Each loop joins end to start with a short cross-fade, 1.5 s for the aurora, the salmon and the Earth and 2 s for
the rest. The salmon's camera sits still on the riverbed, so only the fish cross-fade.

Work by federal employees carries no copyright. NASA's and the Park Service's guidelines only rule out implying
the agency endorses FastBG. The Fish and Wildlife Service's slate declares its b-roll public domain and asks for
the credit "Video courtesy of U.S. Fish & Wildlife Service National Conservation Training Center". No logos
appear, and the slate is cut off.
