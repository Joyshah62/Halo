import catalog from './catalog.json' with { type: 'json' };

export { catalog };

/** Only known teaching models and part IDs cross the wire. Never accept code or model URLs. */
export function cleanScene3D(raw) {
  if (!raw || typeof raw !== 'object' || typeof raw.model !== 'string'
      || !Object.hasOwn(catalog, raw.model)) return null;
  const model = raw.model;
  const parts = catalog[model].parts;
  const focus = typeof raw.focus === 'string' && Object.hasOwn(parts, raw.focus) ? raw.focus : null;
  return { model, ...(focus ? { focus } : {}),
    caption: typeof raw.caption === 'string' ? raw.caption.replace(/\s+/g, ' ').trim().slice(0, 180) : '' };
}

const ids = (model) => Object.keys(catalog[model].parts).join(', ');

export const SCENE3D_INSTRUCTIONS = `INTERACTIVE 3D (optional): when seeing the structure helps, show one of Halo's 3D models:
{"type":"scene3d","model":"brain"|"neuron"|"animal-cell","focus":"<supported part ID, optional>","caption":"<one short sentence connecting the highlighted part to this explanation>"}
brain: a real anatomical human brain the student can turn, look inside, cut in half, touch and ask about. Parts: ${ids('brain')}.
neuron: a simplified schematic. Parts: ${ids('neuron')}.
animal-cell: a simplified schematic. Parts: ${ids('animal-cell')}.
Use the brain whenever the question is about a brain region or something that happens in one (memory, vision, movement, speech, emotion, balance, sleep). Use at most one 3D item per answer, in an early relevant step. The named part is highlighted when this step appears. Keep a written explanation too. The neuron and cell are schematics, not realistic anatomy or molecular structures. Never use the animal-cell model for a plant or bacterial cell, or the neuron model as a synapse close-up. Unsupported topics use sketches or images. Never supply model URLs, geometry, scripts, or invented part IDs.`;

/** The student is inside the 3D explorer, holding a model, and may have just touched one of its parts. */
export function cleanExplorer(raw) {
  const scene = cleanScene3D(raw);
  return scene ? { model: scene.model, ...(scene.focus ? { focus: scene.focus } : {}) } : null;
}
export function explorerInstructions({ model, focus }) {
  const entry = catalog[model];
  const parts = Object.entries(entry.parts).map(([id, part]) => `${id} (${part.label})`).join(', ');
  const touched = focus ? `They have just touched the ${entry.parts[focus].label} (part ID "${focus}"), which is glowing on the model. Unless they say otherwise, "this", "it" and "here" mean that part.`
    : 'They have not touched a part yet.';
  return `═══ INSIDE THE 3D EXPLORER (this replaces the page) ═══
The student is not reading a page. They are holding Halo's interactive 3D model "${entry.title}" and can turn it, look inside it and touch any part. ${touched}
You can point at the model while you talk: put {"type":"scene3d","model":"${model}","focus":"<part ID>"} in a step's ink, and that part lights up and turns toward the student while that step is spoken.
- EVERY step carries exactly one scene3d item, naming the part that step is about. Start on the part they touched; move to other parts when you explain what it connects to or works with, so the student watches the idea travel across the model. Here many scene3d items in one answer are expected.
- Every step also carries exactly one "text": a complete line of 40–90 characters the student can reread later without your voice.
- 3 or 4 steps. No sketch, image, point, arrow, underline, box, math or code items here.
- Say where things are in plain words ("right at the back", "tucked under the temporal lobe"), like someone holding the model with them.
Part IDs you can light up: ${parts}.`;
}
