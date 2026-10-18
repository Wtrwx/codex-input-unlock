/*
 * Runtime quota gate for Codex Desktop.
 *
 * The injected API locates the minified composer quota predicate and builds a
 * conditional CDP breakpoint which clears only the located quota variable.
 */
(() => {
  const identifier = "[A-Za-z_$][\\w$]*";

  function escapeRegex(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }

  function sourceLocation(
    source,
    sourceUrl,
    absoluteOffset,
    quotaVariable,
    hostVariable,
    mode,
    conversationQuotaVariable = null,
    endOffset = null,
  ) {
    const precedingLines = source.slice(0, absoluteOffset).split("\n");
    const result = {
      urlRegex: `^${escapeRegex(sourceUrl)}$`,
      lineNumber: precedingLines.length - 1,
      columnNumber: precedingLines.at(-1).length,
      quotaVariable,
      hostVariable: hostVariable || null,
      conversationQuotaVariable: conversationQuotaVariable || null,
      mode,
    };
    if (Number.isInteger(endOffset) && endOffset > absoluteOffset) {
      const endLines = source.slice(0, endOffset).split("\n");
      result.endLineNumber = endLines.length - 1;
      result.endColumnNumber = endLines.at(-1).length;
    }
    return result;
  }

  function buildConsumerPattern(atomVariable) {
    const hostCheck = `(?:(${identifier})===['"\`]local['"\`]|['"\`]local['"\`]===(${identifier}))`;
    const escapedAtom = escapeRegex(atomVariable);
    return new RegExp(
      `(${identifier})=${identifier}\\((?:` +
        `(?:${hostCheck}&&${escapedAtom}|${escapedAtom}&&${hostCheck})\\)` +
        `|` +
        `${escapedAtom}\\)&&${hostCheck}` +
      `)`,
      "g",
    );
  }

  function extractHost(match) {
    for (let i = 2; i < match.length; i++) {
      if (match[i]) return match[i];
    }
    return null;
  }

  function locateLegacy(source, sourceUrl, atomVariable) {
    const localGatePattern = buildConsumerPattern(atomVariable);
    const localGates = [...source.matchAll(localGatePattern)];
    if (localGates.length !== 1) return null;

    const gate = localGates[0];
    const host = extractHost(gate);
    const tailOffset = gate.index + gate[0].length;
    const tail = source.slice(tailOffset, tailOffset + 18000);
    const assignment = new RegExp(
      `(${identifier})=(${identifier}(?:\\|\\|${identifier})*\\|\\|${escapeRegex(gate[1])})(?=[,;])`,
    ).exec(tail);
    if (!assignment || !tail.includes(`submitDisabled:${assignment[1]}`)) return null;
    const absoluteOffset = tailOffset + assignment.index + assignment[1].length + 1;
    return sourceLocation(source, sourceUrl, absoluteOffset, gate[1], host, "legacy-local-host");
  }

  function locateModern(source, sourceUrl, atomVariable) {
    const consumerPattern = new RegExp(
      `(${identifier})=${identifier}\\(${escapeRegex(atomVariable)}\\)&&(${identifier})`,
      "g",
    );
    const candidates = [];
    for (const match of source.matchAll(consumerPattern)) {
      const window = source.slice(match.index, match.index + 60000);
      const quota = match[1];
      if (!window.includes("submitDisabled:")) continue;
      if (!window.includes("rateLimitSendBlocked:")) continue;
      const propsPattern = new RegExp(
        `rateLimitSendBlocked\\s*:\\s*(${identifier})\\|\\|${escapeRegex(quota)}\\s*,\\s*rateLimitConversationSendBlocked\\s*:\\s*\\1(?:[,}])`,
      );
      const props = propsPattern.exec(window);
      if (!props) continue;
      candidates.push({ match, props });
    }
    if (candidates.length !== 1) return null;
    const { match, props } = candidates[0];
    return sourceLocation(
      source,
      sourceUrl,
      match.index + props.index,
      match[1],
      null,
      "third-party-composer-dual",
      props[1],
    );
  }

  function locateCodexLocalQuota(source, sourceUrl, atomVariable) {
    const consumerPattern = buildConsumerPattern(atomVariable);
    const candidates = [];
    for (const consumer of source.matchAll(consumerPattern)) {
      const quota = consumer[1];
      const host = extractHost(consumer);
      const window = source.slice(consumer.index, consumer.index + 16000);
      const assignmentPattern = new RegExp(
        `(?:let|const|var)\\s+(${identifier})=([^,;]{1,900}?\\b${escapeRegex(quota)}\\b[^,;]{0,900}?)(?:,(${identifier}))?;`,
      );
      const assignment = assignmentPattern.exec(window);
      if (!assignment) continue;
      if (!window.slice(assignment.index, assignment.index + 12000).includes(`submitDisabled:`)) continue;
      const absoluteStart = consumer.index + assignment.index;
      const absoluteEnd = assignment[3]
        ? absoluteStart + assignment[0].lastIndexOf(`,${assignment[3]};`)
        : absoluteStart + assignment[0].length;
      candidates.push({ consumer, quota, host, absoluteStart, absoluteEnd });
    }
    if (candidates.length === 0) return null;
    const candidate = candidates[0];
    return sourceLocation(
      source,
      sourceUrl,
      candidate.absoluteStart,
      candidate.quota,
      candidate.host,
      "codex-local-quota",
      null,
      candidate.absoluteEnd,
    );
  }

  function locateLocalSubmit(source, sourceUrl, atomVariable) {
    const consumerPattern = new RegExp(
      `(${identifier})=${identifier}\\((?:[^()]{0,200}?&&\\s*)?${escapeRegex(atomVariable)}\\)`,
      "g",
    );
    const candidates = [];
    for (const consumer of source.matchAll(consumerPattern)) {
      const quotaVariable = consumer[1];
      const tail = source.slice(consumer.index, consumer.index + 20000);
      const blockPattern = new RegExp(
        `(${identifier})=[^;]{0,8000}?\\|\\|${escapeRegex(quotaVariable)}(?=[,;)|])`,
        "g",
      );
      for (const block of tail.matchAll(blockPattern)) {
        const blockVariable = block[1];
        const absoluteStart = consumer.index + block.index;
        const window = source.slice(absoluteStart, absoluteStart + 12000);
        if (!window.includes(`submitDisabled:${blockVariable}`)) continue;
        const equals = source.indexOf("=", absoluteStart);
        if (equals < 0) continue;
        let start = equals + 1;
        while (start < source.length && /\s/.test(source[start])) start += 1;
        candidates.push({ quotaVariable, start });
      }
    }
    if (candidates.length !== 1) return null;
    const candidate = candidates[0];
    return sourceLocation(
      source,
      sourceUrl,
      candidate.start,
      candidate.quotaVariable,
      null,
      "local-submit-quota",
      null,
      candidate.start + 1,
    );
  }

  function locate(source, sourceUrl) {
    if (typeof source !== "string" || source.length === 0) return null;
    if (typeof sourceUrl !== "string" || sourceUrl.length === 0) return null;

    const atomPattern = new RegExp(
      `(${identifier})=${identifier}\\(${identifier},\\(\\{get:${identifier}\\}\\)=>\\{[^}]{0,1400}?\\.authMethod(?:!==|!=)['"\`]chatgpt['"\`][^}]{0,1400}?\\.rate_limit\\??\\.?allowed`,
      "g",
    );
    let atoms = [...source.matchAll(atomPattern)];
    if (atoms.length === 0) {
      const fallbackAtomPattern = new RegExp(
        `(${identifier})=[^;]{0,300}?\\.authMethod(?:!==|!=)['"\`]chatgpt['"\`][^}]{0,1400}?\\.rate_limit\\??\\.?allowed`,
        "g",
      );
      atoms = [...source.matchAll(fallbackAtomPattern)];
    }
    for (const atom of atoms) {
      const found = locateCodexLocalQuota(source, sourceUrl, atom[1])
        || locateLegacy(source, sourceUrl, atom[1])
        || locateModern(source, sourceUrl, atom[1])
        || locateLocalSubmit(source, sourceUrl, atom[1]);
      if (found) return found;
    }
    return null;
  }

  function condition(location) {
    const safeIdentifier = /^[A-Za-z_$][\w$]*$/;
    if (!safeIdentifier.test(location?.quotaVariable || "")) return null;
    const quota = location.quotaVariable;
    if (location.mode === "codex-local-quota" || location.mode === "legacy-local-host" || location.mode === "local-submit-quota") {
      return `(${quota}=false,false)`;
    }
    if (location.mode === "third-party-composer-dual") {
      if (!safeIdentifier.test(location.conversationQuotaVariable || "")) return null;
      return `(${location.conversationQuotaVariable}=false,${quota}=false,false)`;
    }
    return null;
  }

  const api = { locate, condition };
  globalThis.__codexExternalQuotaGate = api;
  if (typeof module === "object" && module?.exports) module.exports = api;
})();
