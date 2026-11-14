import { test } from 'node:test';
import assert from 'node:assert/strict';
process.env.HALO_MOCK = '1';
process.env.ELEVENLABS_API_KEY = '';

process.env.HALO_DB_PATH = ':memory:';
const { startLesson, continueLesson, lessonGraph, plain } = await import('./lesson.js');
const chapter = { title: 'Calculus', pages: [{ page: 7, text: 'Power rule' }, { page: 8, text: 'Chain rule' }] };
async function start() {
  const events = [];
  const result = await startLesson(chapter, (event, data) => events.push({ event, data }));
  return { ...result, events };
}
async function answer(id, answer, extra = {}) {
  const events = [];
  const result = await continueLesson(id, { answer, action: 'answer', requestID: crypto.randomUUID(), ...extra }, (event, data) => events.push({ event, data }));
  return { ...result, events };
}
const get = (result, event) => result.events.find((e) => e.event === event)?.data;

test('chapter validation rejects empty, scanned, duplicate, and overlong input', async () => {
  for (const pages of [[], [{ page: 1, text: '  ' }], [{ page: -1, text: 'Text' }], [{ page: 1, text: 'Text' }, { page: 1, text: 'Text' }], Array.from({ length: 121 }, (_, i) => ({ page: i + 1, text: 'Text' }))]) {
    await assert.rejects(startLesson({ pages }, () => {}));
  }
});
/** Starts a lesson and gets past the first "what do you think?" so the first concept has been taught. */
async function taught(guess = 'three x') {
  const lesson = await start();
  const first = await answer(lesson.id, guess);
  return { ...first, id: lesson.id, events: [...lesson.events, ...first.events] };
}
const questions = (result) => result.events.filter((e) => e.event === 'question').map((e) => e.data);

test('opens each concept by asking for a guess before teaching anything', async () => {
  const lesson = await start();
  assert.equal(lesson.waiting, true);
  assert.equal(get(lesson, 'concept').n, 1);
  assert.ok(get(lesson, 'plan').concepts.every((c) => [7, 8].includes(c.page)));
  assert.equal(get(lesson, 'question').kind, 'hook');
  assert.equal(lesson.events.some((e) => e.event === 'step'), false);
  const first = await answer(lesson.id, 'three x');
  assert.match(first.events.find((e) => e.event === 'step').data.say, /three x/);
  assert.equal(get(first, 'concept'), undefined);
  assert.equal(get(first, 'question').kind, 'open');
  assert.equal(get(first, 'question').expected, undefined);
  assert.ok(first.events.findIndex((e) => e.event === 'material' && e.data.example) < first.events.findIndex((e) => e.event === 'step'));
});
test('"show me" is a fine answer to the guess and is never graded', async () => {
  const lesson = await start();
  const shown = await answer(lesson.id, '', { action: 'skip' });
  assert.equal(get(shown, 'grade'), undefined);
  assert.equal(get(shown, 'concept'), undefined);
  assert.ok(shown.events.some((e) => e.event === 'step'));
  assert.equal(get(shown, 'question').n, 1);
});
test('partial understanding gets a repair and a smaller question; questions do not consume an attempt', async () => {
  const lesson = await taught();
  const original = questions(lesson).at(-1).ask;
  const partial = await answer(lesson.id, 'something');
  assert.equal(get(partial, 'grade').verdict, 'almost');
  assert.equal(get(partial, 'question').again, true);
  assert.notEqual(get(partial, 'question').ask, original);
  assert.equal(get(partial, 'question').expected, undefined);
  assert.equal(get(partial, 'question').goal, undefined);
  assert.equal(get(partial, 'concept'), undefined);
  const question = await answer(lesson.id, 'Why?');
  assert.equal(get(question, 'grade').verdict, 'question');
  const snap = await lessonGraph.getState({ configurable: { thread_id: lesson.id } });
  assert.equal(snap.values.attempts, 1);
  assert.equal(snap.values.question.goal, original);
  assert.ok(snap.values.exchanges.some((e) => e.text === 'Why?'));
  assert.ok(snap.values.exchanges.some((e) => e.text === 'three x'));
});
test('repeated misses never force advancement without the learner choosing to skip', async () => {
  const lesson = await taught();
  for (let i = 0; i < 3; i++) {
    const result = await answer(lesson.id, "I don't know");
    assert.equal(get(result, 'question').n, 1);
    assert.equal(get(result, 'concept'), undefined);
    assert.equal(get(result, 'question').again, true);
  }
  const skipped = await answer(lesson.id, '', { action: 'skip' });
  assert.equal(get(skipped, 'concept').n, 2);
  assert.equal(get(skipped, 'question').kind, 'hook');
});
test('empty answers and invalid jumps leave checkpoint intact', async () => {
  const lesson = await taught();
  await assert.rejects(answer(lesson.id, ' '));
  await assert.rejects(answer(lesson.id, '', { action: 'jump', concept: 99 }));
  const result = await answer(lesson.id, 'bring the exponent down and subtract one');
  assert.equal(get(result, 'concept').n, 2);
});
test('concurrent duplicate and later retries replay one turn without advancing twice', async () => {
  const lesson = await taught();
  const requestID = crypto.randomUUID();
  const [first, duplicate] = await Promise.all([answer(lesson.id, 'bring exponent down', { requestID }), answer(lesson.id, 'bring exponent down', { requestID })]);
  assert.deepEqual(duplicate, first);
  assert.equal(get(first, 'concept').n, 2);
  assert.deepEqual(await answer(lesson.id, 'bring exponent down', { requestID }), first);
  const snap = await lessonGraph.getState({ configurable: { thread_id: lesson.id } });
  assert.equal(snap.values.current, 1);
});
test('review replaces mastery; wrap never claims skipped or missed concepts were understood', async () => {
  const lesson = await taught();
  await answer(lesson.id, 'bring exponent down');                       // concept 1 understood → guess for 2
  const review = await answer(lesson.id, '', { action: 'jump', concept: 1 });  // back to 1: taught again, no guess
  assert.equal(get(review, 'concept').n, 1);
  assert.equal(get(review, 'question').kind, 'open');
  await answer(lesson.id, '', { action: 'skip' });                       // leave 1 → guess for 2
  await answer(lesson.id, '', { action: 'skip' });                       // "show me" → 2 taught
  await answer(lesson.id, '', { action: 'skip' });                       // leave 2 → guess for 3
  await answer(lesson.id, 'no idea');                                    // 3 taught
  const result = await answer(lesson.id, '', { action: 'skip' });        // leave 3 → wrap
  const finish = get(result, 'finish');
  assert.equal(result.waiting, false);
  assert.deepEqual(finish.nailed, []);
  assert.equal(finish.mastery.length, 3);
  assert.equal(finish.revisit.length, 3);
  await assert.rejects(answer(lesson.id, 'inside changes'));
});
test('a whole lesson reads as a conversation: guess, teach, check, next', async () => {
  const lesson = await taught();
  const order = [];
  let turn = lesson;
  for (const reply of ['bring the exponent down and subtract one', 'the x squared plus one', 'x squared plus one is inside', 'no idea', 'the inside is also changing, so two x']) {
    order.push(...turn.events.filter((e) => ['concept', 'question', 'grade', 'finish'].includes(e.event)).map((e) => e.event === 'question' ? e.data.kind : e.event));
    turn = await answer(lesson.id, reply);
  }
  order.push(...turn.events.filter((e) => ['concept', 'question', 'grade', 'finish'].includes(e.event)).map((e) => e.event === 'question' ? e.data.kind : e.event));
  assert.deepEqual(order, ['concept', 'hook', 'open', 'grade', 'concept', 'hook', 'choice', 'grade', 'concept', 'hook', 'open', 'grade', 'finish']);
  assert.deepEqual(get(turn, 'finish').nailed.length, 3);
});
test('a marker\'s verdict is cut from the start of a reply; the substance stays', () => {
  assert.equal(plain("Spot on, Joy! HTTP only understands text or raw bytes."), 'HTTP only understands text or raw bytes.');
  assert.equal(plain("That's spot on, Joy — writing a function and giving it an address is the whole recipe."), 'Writing a function and giving it an address is the whole recipe.');
  assert.equal(plain("Exactly right. The inside changes too."), 'The inside changes too.');
  assert.equal(plain("You said three x... hold onto that three."), 'You said three x... hold onto that three.');
  assert.equal(plain("Exactly."), 'Exactly.');
  assert.equal(plain("Correctly placing the decorator matters here."), 'Correctly placing the decorator matters here.');
});
