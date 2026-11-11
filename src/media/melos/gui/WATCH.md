# Melos Viewing Platform

`watch.html` is the public-facing live page.

## Layout
- **Left / main**: embedded live stream (Kick player)
- **Right sidebar**: interactive controls
  - Crowd prompt (mood / tone suggestions)
  - Pedal builder (submit effects for instruments)
  - Submitted pedals list
  - Quick option hints (tempo, energy)

## Kick integration
1. Start your Kick stream as usual.
2. Open the page with the channel name:
   ```
   watch.html?kick=YOUR_CHANNEL
   ```
   or set `window.KICK_CHANNEL = "YOUR_CHANNEL"` before load.
3. The page embeds `https://player.kick.com/YOUR_CHANNEL`.

If no channel is set, a placeholder is shown with instructions.

## Backend
Uses the same Melos endpoints already defined:
- `POST /api/melos/live/modulate` — crowd prompts and hints
- `POST /api/melos/pedals/submit`
- `GET  /api/melos/pedals`

Serve `watch.html` from the Arcis static path (or any origin that can reach the API).

## Performer side
The performer continues to use the main Melos GUI (`index.html`) or the Live tab to approve/activate pedals and control the set. Viewers only submit; the performer decides what is used.
