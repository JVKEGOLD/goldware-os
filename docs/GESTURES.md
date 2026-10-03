# Vision gestures

Every hand gesture GoldWare Vision understands. This file is generated from the catalog in
`dashboard/gestures.js` by `python3 scripts/gestures_doc.py`; edit the catalog, not this file.
The same catalog drives the animated demos: open `/dashboard/gestures.html` on the local
dashboard server to watch each one.

Vision Mode starts locked every time it turns on. Your unlock gesture is private: it is never
drawn, named, or described anywhere in GoldWare.

## Pointer

Vision Mode's pointer style: move and click with one hand.

| Gesture | How | Hold | Does |
|---|---|---|---|
| Point | Index finger up, the other fingers curled. Move your hand. |  | Moves the pointer like a finger on a trackpad. The gap between your thumb and index tips sets the speed: a wide L is up to 2.5x, thumb close to the finger is 0.25x for fine work. |
| Pinch to click | Touch your thumb tip to your index tip and let go within 0.6 s, without moving. |  | Clicks where the pointer is. Two pinches within 0.6 s in the same spot double-click. The pointer holds still for a moment after a click so a double-click lands where you aimed. |
| Pinch and move to scroll | Pinch, keep holding, and move your hand in any direction. |  | Scrolls: the page follows your hand. Let go mid-move to fling it; pinch again to catch it. |
| Rest | Open hand or fist. |  | Nothing. The pointer stays where it is while you reposition, like lifting a mouse off the desk. |
| Four fingers: switch to Quadrants | Four fingers up with the thumb folded across your palm. Hold for 0.8 s. | 0.8 s | Switches to Quadrants and tiles your windows into the four corners of the screen. |
| Let's work | Both hands with thumb, index, and middle out (ring and little curled). Touch your thumb tips together for a moment, then pull your hands apart. | 0.2 s | Opens one terminal in each corner of the screen, the same as saying "Let's work". It fires once, until you drop the shape. |
| Lock up | Both hands open and apart for a moment, then close both into fists within a second. | 0.3 s | Closes every terminal except those with an agent in the middle of a task, the same as saying "Lock up". |
| Clear out | Both hands open for a moment, then close one into a fist and keep the other open for half a second. | 0.5 s | Closes only the Hermes terminals nobody has written in, the same as saying "Clear out". |

## Quadrants

Dictate into any corner of the screen.

| Gesture | How | Hold | Does |
|---|---|---|---|
| Open hand: back to the pointer | All four fingers up and the thumb spread wide. Hold for 0.8 s. | 0.8 s | Leaves Quadrants and goes back to the pointer. |
| 1 to 4 fingers: dictate into a corner | Hold up 1, 2, 3, or 4 fingers (the thumb does not count). Keep them up, talk, then lower your hand. | 0.45 s | Picks a corner: 1 top left, 2 top right, 3 bottom left, 4 bottom right. That window comes forward, the cursor goes into its text box, and GoldWare listens while your fingers stay up. Lowering them pastes what you said. |
| Fist: rest in Quadrants | Make a fist. |  | Rests. No corner is picked, so it is the safe place between messages. |

## Pointer and Quadrants

Work in both styles, after a hand dictation.

| Gesture | How | Hold | Does |
|---|---|---|---|
| Swipe left: send | Open hand, three or more fingers up, swept quickly to your left as you face the screen: about a fifth of the camera's view in half a second. |  | Presses Return in the window your last hand dictation pasted into, so the message sends. Only within 2 minutes of the paste, only if that window is still in front, and only if nothing was typed since. A pointing hand or a pinch never sends. |
| Pinky: clear the paste | Little finger up on its own, thumb not spread out. Hold for 0.8 s. | 0.8 s | Deletes what your last hand dictation pasted, under the same rules as sending. |

## Any style

Work whenever Vision Mode is on.

| Gesture | How | Hold | Does |
|---|---|---|---|
| OK sign: hide or show the mirror | Thumb and index tips touching in a ring, the other three fingers straight. Hold for 0.8 s. | 0.8 s | Hides the camera mirror under the notch while Vision keeps running, or shows it again. It is never a click. |
| Praying hands: lock | Both hands, palms together and fingertips touching. Hold for 0.8 s. | 0.8 s | Locks Vision Mode. Your hands drive nothing until your unlock gesture. It also locks by itself after a minute with no hand in view. |

## Locked

Vision Mode starts locked, so a hand passing by never acts.

| Gesture | How | Hold | Does |
|---|---|---|---|
| Your unlock gesture | Private. You choose it, and GoldWare never shows it. |  | Unlocks Vision Mode. Vision starts locked every time it turns on, so a hand passing by never acts. |

## Mirror scan

No unlock needed. Open the mirror behind the notch and hold something up.

| Gesture | How | Hold | Does |
|---|---|---|---|
| Hold up a document to scan | Open the mirror (rest the pointer behind the camera notch) and hold a card, receipt, or page still in view. | 1.1 s | A gold outline closes around it as you hold still, then it is read on this Mac. The image is never saved. |
| Thumbs up: file the scan | After a scan is read: a fist with the thumb pointing straight up. Hold for 0.7 s. | 0.7 s | Files it as one task with what it is, any due date, and the details it read. Nothing is sent to anyone. |
| Two fingers: copy the scan | After a scan is read: two fingers up. Hold for 0.6 s. | 0.6 s | Copies what it read to the clipboard. |
| Fist: discard the scan | After a scan is read, or when it failed: make a fist. Hold for 0.6 s. | 0.6 s | Throws the scan away. Nothing is kept. |

## For developers

`dashboard/gestures.js` has no dependencies. Include it with `dashboard/gestures.css`, then:

```js
GoldWareGestures.list()   // [{id, name, mode, does, how, holdMs}]
GoldWareGestures.render(el, id, {loop: true, size: 'm'})   // size 's', 'm' or 'l'
```

`render` returns `{play, pause, step(n), destroy}`. Each demo is keyboard reachable (Space plays
or pauses, the arrow keys step), and with reduced motion it shows one still per step instead of
playing. `tests/test_gestures.py` fails when the Swift app recognises a gesture with no demo.
