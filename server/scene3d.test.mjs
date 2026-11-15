import { test } from 'node:test';
import assert from 'node:assert/strict';
import { catalog, cleanScene3D } from '../shared/scene3d/schema.js';
import { cleanStep } from './steps.js';
import { cleanScene } from './lesson-material.js';
import { buildSystemPrompt } from './prompt.js';
import { parseAnswer } from './web.js';

test('3D scenes use only known models and part IDs, never executable content or asset URLs', () => {
  for (const raw of [null, 'neuron', {}, { model: '__proto__' }, { model: 'constructor' }, { model: 'https://example.com/brain.glb' }]) {
    assert.equal(cleanScene3D(raw), null);
  }
  assert.deepEqual(cleanScene3D({ model: 'neuron', focus: 'axon', caption: ' Follow  the\naxon ', url: 'evil', script: 'evil' }),
    { model: 'neuron', focus: 'axon', caption: 'Follow the axon' });
  assert.deepEqual(cleanScene3D({ model: 'animal-cell', focus: 'axon', caption: 12 }), { model: 'animal-cell', caption: '' });
  assert.equal(cleanScene3D({ model: 'neuron', caption: 'x'.repeat(300) }).caption.length, 180);
  for (const [model, entry] of Object.entries(catalog)) {
    for (const focus of Object.keys(entry.parts)) assert.equal(cleanScene3D({ model, focus }).focus, focus);
  }
});

test('streamed answers retain supported scenes and discard unsupported scenes while preserving the explanation', () => {
  const step = cleanStep({ say: 'The axon carries the signal.', ink: [
    { type: 'scene3d', model: 'neuron', focus: 'axon', caption: 'Follow the axon.' },
    { type: 'scene3d', model: 'invented-brain' }, { type: 'text', value: 'Axon → terminals' },
  ] });
  assert.deepEqual(step.ink.map(i => i.type), ['scene3d', 'text']);
  assert.equal(step.ink[0].focus, 'axon');
  assert.equal(step.say, 'The axon carries the signal.');
});

test('lesson material carries the same scene contract alongside its existing 2D diagram', () => {
  const scene = cleanScene({ scene3d: { model: 'animal-cell', focus: 'nucleus' }, visual: { kind: 'flow', nodes: [{ label: 'DNA' }] } },
    [{ page: 1, text: 'The nucleus contains most of the DNA.' }], { n: 1, name: 'Nucleus', page: 1 });
  assert.equal(scene.scene3d.focus, 'nucleus');
  assert.equal(scene.visual.nodes[0].label, 'DNA');
  assert.equal(cleanScene({}, [], { n: 1, name: 'Algebra', page: 1 }).scene3d, null);
});

test('3D answer instructions are advertised only to clients that support them', () => {
  assert.ok(!buildSystemPrompt().includes('"type":"scene3d"'));
  const prompt = buildSystemPrompt({ supports3D: true, pointing: true });
  assert.ok(prompt.includes('"type":"scene3d"'));
  assert.ok(prompt.includes('POINTING AT THE PAGE'));
});

test('web explanations extract optional 3D selections without leaking metadata into prose', () => {
  const answer = parseAnswer('## Neurons\nSignals travel along an axon.\nTAKEAWAY: Follow the signal.\nSAY: Here is the axon.\nSCENE3D: {"model":"neuron","focus":"axon","caption":"Follow the signal."}');
  assert.equal(answer.scene3d.focus, 'axon');
  assert.equal(answer.sections[0].text, 'Signals travel along an axon.');
  assert.equal(answer.say, 'Here is the axon.');
  for (const line of ['not JSON', '{"model":"invented"}']) {
    const out = parseAnswer(`## Cells\nA written explanation.\nSCENE3D: ${line}`);
    assert.equal(out.scene3d, null);
    assert.equal(out.sections[0].text, 'A written explanation.');
  }
});
