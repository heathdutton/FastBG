# Fixture sources

`../fetch-fixtures.sh` downloads the originals into `src/` (checked by sha1) and derives the 1920x1080 frames.
`../make-green-fixtures.swift` builds the green screen set from `portrait-home.jpg`. Only this file and
`.gitignore` are tracked.

| File | From | Author | License | Changes |
|------|------|--------|---------|---------|
| `portrait-home.jpg` | [Woman engaged in a phone conversation while working on her laptop at home](https://commons.wikimedia.org/wiki/File:Woman_engaged_in_a_phone_conversation_while_working_on_her_laptop_at_home.jpg) | Shixart1985 | [CC BY 2.0](https://creativecommons.org/licenses/by/2.0/) | cropped to 16:9, scaled to 1920x1080, converted Adobe RGB to sRGB |
| `portrait-brick.jpg` | [Woman smiling in front of a laptop while holding glasses in one hand and a card in the other one](https://commons.wikimedia.org/wiki/File:Woman_smiling_in_front_of_a_laptop_while_holding_glasses_in_one_hand_and_a_card_in_the_other_one.jpg) | Shixart1985 | [CC BY 2.0](https://creativecommons.org/licenses/by/2.0/) | cropped to 16:9, scaled to 1920x1080 |
| `studio.jpg` | [Pow Salud Studio](https://commons.wikimedia.org/wiki/File:Pow_Salud_Studio.jpg) | FilBox101 | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) | none |
| `room-office.jpg` | [オオサカンスペースの集中エリア](https://commons.wikimedia.org/wiki/File:%E3%82%AA%E3%82%AA%E3%82%B5%E3%82%AB%E3%83%B3%E3%82%B9%E3%83%9A%E3%83%BC%E3%82%B9%E3%81%AE%E9%9B%86%E4%B8%AD%E3%82%A8%E3%83%AA%E3%82%A2_(6837921264).jpg) | ec_osaki | [CC BY 2.0](https://creativecommons.org/licenses/by/2.0/) | cropped to 16:9, scaled to 1920x1080 |
| `room-desk.jpg` | [Desktop after work (Unsplash)](https://commons.wikimedia.org/wiki/File:Desktop_after_work_(Unsplash).jpg) | Luca Bravo | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) | cropped to 16:9, scaled to 1920x1080 |
| `green-partial.png`, `green-full.png`, `green-alpha.png`, `green-screen.png` | derived from `portrait-home.jpg` | | CC BY 2.0, as the source | person cut out with Vision, composited over a synthetic green screen |

What each one is for:

- `portrait-home.jpg`: head and shoulders, centred, loose curly hair against a light wall, a hand at the frame edge.
- `portrait-brick.jpg`: off-centre subject, curly hair against brick, both arms raised.
- `studio.jpg`: a streamer's webcam shot, hat, glasses and a boom mic across the body, blue-lit shelves.
- `room-office.jpg`: an empty office with a blue mesh chair where a person would sit and more chairs behind, the
  benchmark's room, and its chair problem.
- `room-desk.jpg`: a dark desk and a white shell chair, a second room.
- `green-partial.png`: the screen covers the middle 55% of the width and 36% of the background, the room shows
  around it, the lighting is uneven and there's some green spill on the person's edge.
- `green-full.png`: the same person with the screen filling the background.
- `green-alpha.png`: the person's true alpha in both green images.
- `green-screen.png`: where the screen is in `green-partial.png`.
