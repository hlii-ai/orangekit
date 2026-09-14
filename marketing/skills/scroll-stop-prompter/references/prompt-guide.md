# Detailed guide to Prompts A/B/C

## Prompt A — Assembled Shot

A premium studio shot of the finished product. Elements to include:

- Camera angle (3/4 view, straight on, etc.)
- Lighting (studio three-point, rim light, etc.)
- Background (gradient, reflective surface, etc.)
- Material texture description
- Resolution/aspect-ratio directives (`--ar 16:9`, `--v 6`, etc.)

## Prompt B — Deconstructed Shot

An exploded view breaking the product into its components. Elements to include:

- Spatial placement of each part
- Spacing and alignment between parts
- Material texture of individual parts
- Keeping the same lighting environment

## Prompt C — Video Transition

A transition animation from deconstructed → assembled or assembled → deconstructed. Elements to include:

- Direction and speed of the transition
- Camera movement (orbiting, push-in, etc.)
- Motion blur / trailing effects
- Whether it can loop
- Frame rate directive (24fps)
- Length (3–5 seconds)

## AI model optimization mapping

| prompt type   | recommended model | model-specific suffix                  |
| ------------- | ---------------- | -------------------------------------- |
| A (image)     | Midjourney v6    | `--ar 16:9 --v 6 --style raw`          |
| A (image)     | DALL-E 3         | add "Photorealistic" at the start of the prompt |
| A (image)     | Stable Diffusion | include a negative prompt              |
| B (image)     | Midjourney v6    | `--ar 16:9 --v 6 --style raw`          |
| C (video)     | Runway Gen-3     | the "Camera: [move], Duration: [sec]" structure |
| C (video)     | Kling            | concentrate the motion directive in the first sentence |
| C (video)     | Pika             | the "Motion: [type]" prefix            |
