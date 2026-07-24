#!/usr/bin/env node
import assert from 'node:assert/strict';
import {getEventListeners} from 'node:events';
import {pathToFileURL} from 'node:url';
import {resolve} from 'node:path';

const modulePath = process.argv[2];
if (!modulePath) {
	throw new Error('usage: p_limit_abortsignal_probe.mjs /path/to/index.js');
}
const {default: pLimit, limitFunction} = await import(pathToFileURL(resolve(modulePath)).href);
const cases = [];

const deferred = () => {
	let resolvePromise;
	const promise = new Promise(resolve => {
		resolvePromise = resolve;
	});
	return {promise, resolve: resolvePromise};
};
const capture = promise => promise.then(value => ({fulfilled: true, value}), reason => ({fulfilled: false, reason}));
const tick = () => new Promise(resolvePromise => setImmediate(resolvePromise));

async function run(id, test) {
	let timer;
	try {
		await Promise.race([
			test(),
			new Promise((_, reject) => {
				timer = setTimeout(() => reject(new Error('case timed out')), 2000);
			}),
		]);
		cases.push({id, passed: true, details: {}});
	} catch (error) {
		cases.push({id, passed: false, details: {name: error?.name ?? 'Error', message: String(error?.message ?? error)}});
	} finally {
		clearTimeout(timer);
	}
}

await run('queued_exact_reason', async () => {
	const controller = new AbortController();
	const limit = pLimit({concurrency: 1, signal: controller.signal});
	const gate = deferred();
	const running = limit(async () => {
		await gate.promise;
		return 'running-result';
	});
	let queuedRuns = 0;
	const queued = [capture(limit(() => queuedRuns++)), capture(limit(() => queuedRuns++))];
	assert.equal(limit.pendingCount, 2);
	const reason = {case: 'queued'};
	controller.abort(reason);
	assert.equal(limit.pendingCount, 0, 'pendingCount must drain synchronously');
	for (const result of await Promise.all(queued)) {
		assert.equal(result.fulfilled, false);
		assert.equal(result.reason, reason);
	}
	assert.equal(queuedRuns, 0);
	gate.resolve();
	assert.equal(await running, 'running-result');
});

await run('future_immediate_rejection', async () => {
	const controller = new AbortController();
	const limit = pLimit({concurrency: 1, signal: controller.signal});
	const reason = Symbol('future');
	controller.abort(reason);
	let ran = false;
	const result = await capture(limit(() => {
		ran = true;
	}));
	assert.equal(result.fulfilled, false);
	assert.equal(result.reason, reason);
	assert.equal(ran, false);
	assert.equal(limit.activeCount, 0);
	assert.equal(limit.pendingCount, 0);
});

await run('running_untouched', async () => {
	const controller = new AbortController();
	const limit = pLimit({concurrency: 1, signal: controller.signal});
	const gate = deferred();
	const running = limit(async () => {
		await gate.promise;
		return 42;
	});
	controller.abort(new Error('queued only'));
	gate.resolve();
	assert.equal(await running, 42);
	await tick();
	assert.equal(limit.activeCount, 0);
});

await run('pre_aborted_signal', async () => {
	const controller = new AbortController();
	const reason = {case: 'pre-aborted'};
	controller.abort(reason);
	const limit = pLimit({concurrency: 1, signal: controller.signal});
	let ran = false;
	const result = await capture(limit(() => {
		ran = true;
	}));
	assert.equal(result.fulfilled, false);
	assert.equal(result.reason, reason);
	assert.equal(ran, false);
	assert.equal(getEventListeners(controller.signal, 'abort').length, 0);
	assert.equal(controller.signal.onabort, null);
});

await run('falsey_reason_matrix', async () => {
	for (const reason of [null, false, 0, '', Number.NaN]) {
		const controller = new AbortController();
		const limit = pLimit({concurrency: 1, signal: controller.signal});
		const gate = deferred();
		const running = limit(() => gate.promise);
		const pending = capture(limit(() => 'must not run'));
		controller.abort(reason);
		const queuedResult = await pending;
		assert.equal(queuedResult.fulfilled, false);
		assert.ok(Object.is(queuedResult.reason, reason), `queued reason mismatch for ${String(reason)}`);
		const futureResult = await capture(limit(() => 'must not run'));
		assert.equal(futureResult.fulfilled, false);
		assert.ok(Object.is(futureResult.reason, reason), `future reason mismatch for ${String(reason)}`);
		gate.resolve();
		await running;
	}
});

await run('reject_on_clear_enabled', async () => {
	const controller = new AbortController();
	const limit = pLimit({concurrency: 1, rejectOnClear: true, signal: controller.signal});
	const gate = deferred();
	const running = limit(() => gate.promise);
	const cleared = capture(limit(() => 'cleared'));
	limit.clearQueue();
	const clearResult = await cleared;
	assert.equal(clearResult.fulfilled, false);
	assert.equal(clearResult.reason?.name, 'AbortError');
	assert.equal(controller.signal.aborted, false);
	gate.resolve();
	await running;
	assert.equal(await limit(() => 'later'), 'later');
	const reason = {case: 'later-abort'};
	controller.abort(reason);
	const aborted = await capture(limit(() => 'never'));
	assert.equal(aborted.reason, reason);
});

await run('reject_on_clear_disabled', async () => {
	const limit = pLimit(1);
	const gate = deferred();
	const running = limit(() => gate.promise);
	let discardedRan = false;
	let settled = false;
	limit(() => {
		discardedRan = true;
	}).finally(() => {
		settled = true;
	});
	limit.clearQueue();
	gate.resolve();
	await running;
	await tick();
	assert.equal(discardedRan, false);
	assert.equal(settled, false);
	assert.equal(await limit(() => 'future'), 'future');
});

await run('listener_lifecycle', async () => {
	const listenerCount = signal => getEventListeners(signal, 'abort').length + (signal.onabort === null ? 0 : 1);
	const controller = new AbortController();
	const limit = pLimit({concurrency: 1, signal: controller.signal});
	assert.equal(listenerCount(controller.signal), 0);
	const gate = deferred();
	const running = limit(() => gate.promise);
	assert.equal(listenerCount(controller.signal), 0, 'running-only work must not retain an abort listener');
	const queued = limit(() => 'queued');
	assert.ok(listenerCount(controller.signal) <= 1 && listenerCount(controller.signal) > 0);
	gate.resolve();
	await Promise.all([running, queued]);
	await tick();
	assert.equal(listenerCount(controller.signal), 0, 'natural drain must remove the listener');

	for (let wave = 0; wave < 3; wave++) {
		const waveGate = deferred();
		const active = limit(() => waveGate.promise);
		const pending = limit(() => wave);
		assert.ok(listenerCount(controller.signal) <= 1);
		waveGate.resolve();
		await Promise.all([active, pending]);
		await tick();
		assert.equal(listenerCount(controller.signal), 0);
	}

	const clearGate = deferred();
	const active = limit(() => clearGate.promise);
	limit(() => 'discarded');
	limit.clearQueue();
	assert.equal(listenerCount(controller.signal), 0, 'clearQueue must remove the listener');
	clearGate.resolve();
	await active;

	const abortGate = deferred();
	const abortActive = limit(() => abortGate.promise);
	const rejected = capture(limit(() => 'aborted'));
	controller.abort('abort-reason');
	assert.equal(listenerCount(controller.signal), 0, 'abort must remove the listener');
	assert.equal((await rejected).reason, 'abort-reason');
	abortGate.resolve();
	await abortActive;
});

await run('map_propagation', async () => {
	const controller = new AbortController();
	const limit = pLimit({concurrency: 2, signal: controller.signal});
	const reason = {case: 'map'};
	controller.abort(reason);
	let calls = 0;
	const result = await capture(limit.map([1, 2, 3], value => {
		calls++;
		return value;
	}));
	assert.equal(result.fulfilled, false);
	assert.equal(result.reason, reason);
	assert.equal(calls, 0);
});

await run('limit_function_propagation', async () => {
	const controller = new AbortController();
	const gate = deferred();
	let calls = 0;
	const limited = limitFunction(async value => {
		calls++;
		if (value === 'running') {
			await gate.promise;
		}
		return value;
	}, {concurrency: 1, signal: controller.signal});
	const running = limited('running');
	const reason = {case: 'limitFunction'};
	controller.abort(reason);
	const future = await capture(limited('future'));
	assert.equal(future.fulfilled, false);
	assert.equal(future.reason, reason);
	gate.resolve();
	assert.equal(await running, 'running');
	assert.equal(calls, 1);
});

const passed = cases.every(item => item.passed);
console.log(JSON.stringify({schema_version: 1, passed, cases}));
process.exitCode = passed ? 0 : 1;
