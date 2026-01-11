#!/usr/bin/env node
/**
 * CPU Profile Analyzer
 * Compares two V8 CPU profiles and identifies performance regressions
 * 
 * Usage: node cpuprofile-analyzer.js <before.cpuprofile> <after.cpuprofile> [output.md]
 */

const fs = require('fs');
const path = require('path');

// Parse command line arguments
const args = process.argv.slice(2);
if (args.length < 2) {
    console.error('Usage: node cpuprofile-analyzer.js <before.cpuprofile> <after.cpuprofile> [output.md]');
    process.exit(1);
}

const beforeFile = args[0];
const afterFile = args[1];
const outputFile = args[2] || 'cpu-profile-analysis.md';

// Load profiles
console.log(`Loading ${beforeFile}...`);
const before = JSON.parse(fs.readFileSync(beforeFile, 'utf8'));
console.log(`Loading ${afterFile}...`);
const after = JSON.parse(fs.readFileSync(afterFile, 'utf8'));

// ============================================================================
// Helper Functions
// ============================================================================

function getTotalHits(data) {
    let total = 0;
    for (const node of data.nodes || []) {
        total += node.hitCount || 0;
    }
    return total;
}

function getProfileDuration(data) {
    return (data.endTime - data.startTime) / 1000000; // Convert to seconds
}

function aggregateByFunction(data, filterNodeModules = false) {
    const stats = {};
    for (const node of data.nodes || []) {
        const cf = node.callFrame || {};
        const funcName = cf.functionName || '(anonymous)';
        const url = cf.url || '';
        const line = cf.lineNumber || -1;
        const hitCount = node.hitCount || 0;

        if (hitCount > 0 && url && url.includes('Backend')) {
            if (filterNodeModules && url.includes('node_modules')) continue;
            
            const key = funcName + '|' + url + ':' + line;
            if (!stats[key]) {
                stats[key] = { 
                    hitCount: 0, 
                    func: funcName, 
                    url: url, 
                    line: line,
                    positionTicks: []
                };
            }
            stats[key].hitCount += hitCount;
            if (node.positionTicks) {
                stats[key].positionTicks.push(...node.positionTicks);
            }
        }
    }
    return stats;
}

function aggregateByFile(data) {
    const stats = {};
    for (const node of data.nodes || []) {
        const cf = node.callFrame || {};
        const url = cf.url || '';
        const hitCount = node.hitCount || 0;

        if (hitCount > 0 && url && url.includes('Backend')) {
            const file = url.replace('file:///usr/code/src/Backend/', '');
            if (!stats[file]) {
                stats[file] = { hitCount: 0 };
            }
            stats[file].hitCount += hitCount;
        }
    }
    return stats;
}

function buildParentMap(data) {
    const parentMap = {};
    for (const node of data.nodes || []) {
        if (node.children) {
            for (const childId of node.children) {
                parentMap[childId] = node.id;
            }
        }
    }
    return parentMap;
}

function buildNodeMap(data) {
    const nodeMap = {};
    for (const node of data.nodes || []) {
        nodeMap[node.id] = node;
    }
    return nodeMap;
}

function getCallStack(nodeMap, parentMap, nodeId, maxDepth = 30) {
    const stack = [];
    let current = nodeId;
    let depth = 0;
    
    while (current && depth < maxDepth) {
        const node = nodeMap[current];
        if (!node) break;
        const cf = node.callFrame || {};
        stack.push({
            func: cf.functionName || '(anonymous)',
            url: (cf.url || '').replace('file:///usr/code/src/Backend/', ''),
            line: cf.lineNumber,
            hitCount: node.hitCount
        });
        current = parentMap[current];
        depth++;
    }
    return stack.reverse();
}

// ============================================================================
// Analysis Functions
// ============================================================================

function compareProfiles(beforeStats, afterStats, beforeTotal, afterTotal) {
    const comparison = [];
    const allKeys = new Set([...Object.keys(beforeStats), ...Object.keys(afterStats)]);

    for (const key of allKeys) {
        const beforeHits = (beforeStats[key] && beforeStats[key].hitCount) || 0;
        const afterHits = (afterStats[key] && afterStats[key].hitCount) || 0;

        const beforePct = (beforeHits / beforeTotal) * 100;
        const afterPct = (afterHits / afterTotal) * 100;
        const pctDiff = afterPct - beforePct;

        const stats = afterStats[key] || beforeStats[key];
        if (!stats) continue;
        
        const url = stats.url || stats.file || key;
        comparison.push({
            func: stats.func || '(file)',
            url: url.replace('file:///usr/code/src/Backend/', ''),
            line: stats.line || 0,
            beforePct,
            afterPct,
            pctDiff,
            beforeHits,
            afterHits,
            isNew: beforeHits === 0 && afterHits > 0,
            isRemoved: beforeHits > 0 && afterHits === 0
        });
    }

    return comparison;
}

function findCallStacksForFunction(data, funcName, urlPattern) {
    const parentMap = buildParentMap(data);
    const nodeMap = buildNodeMap(data);
    const stacks = [];
    
    for (const node of data.nodes || []) {
        const cf = node.callFrame || {};
        if (cf.functionName === funcName && cf.url && cf.url.includes(urlPattern)) {
            stacks.push(getCallStack(nodeMap, parentMap, node.id));
        }
    }
    return stacks;
}

// ============================================================================
// Report Generation
// ============================================================================

function generateMarkdownReport() {
    const beforeTotal = getTotalHits(before);
    const afterTotal = getTotalHits(after);
    const beforeDuration = getProfileDuration(before);
    const afterDuration = getProfileDuration(after);

    const beforeStats = aggregateByFunction(before);
    const afterStats = aggregateByFunction(after);
    const beforeUserStats = aggregateByFunction(before, true);
    const afterUserStats = aggregateByFunction(after, true);
    const beforeFileStats = aggregateByFile(before);
    const afterFileStats = aggregateByFile(after);

    const allComparison = compareProfiles(beforeStats, afterStats, beforeTotal, afterTotal);
    const userComparison = compareProfiles(beforeUserStats, afterUserStats, beforeTotal, afterTotal);
    const fileComparison = compareProfiles(beforeFileStats, afterFileStats, beforeTotal, afterTotal);

    // Sort comparisons
    const worseAll = allComparison.filter(x => x.pctDiff > 0.05).sort((a, b) => b.pctDiff - a.pctDiff);
    const worseUser = userComparison.filter(x => x.pctDiff > 0.02).sort((a, b) => b.pctDiff - a.pctDiff);
    const worseFiles = fileComparison.filter(x => x.pctDiff > 0.05).sort((a, b) => b.pctDiff - a.pctDiff);
    const improvedAll = allComparison.filter(x => x.pctDiff < -0.1).sort((a, b) => a.pctDiff - b.pctDiff);

    // Calculate category totals
    let beforeNodeModules = 0, afterNodeModules = 0;
    let beforeUserCode = 0, afterUserCode = 0;
    
    for (const key in beforeStats) {
        if (key.includes('node_modules')) {
            beforeNodeModules += beforeStats[key].hitCount;
        } else {
            beforeUserCode += beforeStats[key].hitCount;
        }
    }
    for (const key in afterStats) {
        if (key.includes('node_modules')) {
            afterNodeModules += afterStats[key].hitCount;
        } else {
            afterUserCode += afterStats[key].hitCount;
        }
    }

    // Generate markdown
    let md = `# CPU Profile Analysis Report

**Generated:** ${new Date().toISOString()}

## Profile Overview

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| Duration | ${beforeDuration.toFixed(2)}s | ${afterDuration.toFixed(2)}s | ${(afterDuration - beforeDuration).toFixed(2)}s |
| Total Samples | ${beforeTotal.toLocaleString()} | ${afterTotal.toLocaleString()} | ${(afterTotal - beforeTotal).toLocaleString()} (${((afterTotal - beforeTotal) / beforeTotal * 100).toFixed(1)}%) |
| User Code Samples | ${beforeUserCode.toLocaleString()} | ${afterUserCode.toLocaleString()} | ${(afterUserCode - beforeUserCode).toLocaleString()} |
| Node Modules Samples | ${beforeNodeModules.toLocaleString()} | ${afterNodeModules.toLocaleString()} | ${(afterNodeModules - beforeNodeModules).toLocaleString()} |
| Total Nodes | ${before.nodes.length.toLocaleString()} | ${after.nodes.length.toLocaleString()} | ${(after.nodes.length - before.nodes.length).toLocaleString()} |

---

## 🔴 Critical Regressions (All Code)

Functions with significantly higher relative CPU usage in the "after" profile:

| % Diff | Before % | After % | Before # | After # | Function | Location |
|--------|----------|---------|----------|---------|----------|----------|
`;

    for (const item of worseAll.slice(0, 25)) {
        const status = item.isNew ? '🆕' : '';
        md += `| ${item.pctDiff.toFixed(2)} | ${item.beforePct.toFixed(2)} | ${item.afterPct.toFixed(2)} | ${item.beforeHits} | ${item.afterHits} | \`${item.func.substring(0, 35)}\` ${status} | ${item.url}:${item.line} |\n`;
    }

    md += `
---

## 🟠 User Code Regressions

Functions in your codebase (excluding node_modules) that got worse:

| % Diff | Before % | After % | Before # | After # | Function | Location |
|--------|----------|---------|----------|---------|----------|----------|
`;

    for (const item of worseUser.slice(0, 20)) {
        const status = item.isNew ? '🆕' : '';
        md += `| ${item.pctDiff.toFixed(2)} | ${item.beforePct.toFixed(2)} | ${item.afterPct.toFixed(2)} | ${item.beforeHits} | ${item.afterHits} | \`${item.func.substring(0, 35)}\` ${status} | ${item.url}:${item.line} |\n`;
    }

    md += `
---

## 📁 Files with Higher CPU Usage

| % Diff | Before % | After % | File |
|--------|----------|---------|------|
`;

    for (const item of worseFiles.slice(0, 15)) {
        md += `| ${item.pctDiff.toFixed(2)} | ${item.beforePct.toFixed(2)} | ${item.afterPct.toFixed(2)} | ${item.url} |\n`;
    }

    md += `
---

## 🟢 Improvements

Functions that improved (lower CPU usage in "after"):

| % Diff | Before % | After % | Function | Location |
|--------|----------|---------|----------|----------|
`;

    for (const item of improvedAll.slice(0, 15)) {
        md += `| ${item.pctDiff.toFixed(2)} | ${item.beforePct.toFixed(2)} | ${item.afterPct.toFixed(2)} | \`${item.func.substring(0, 35)}\` | ${item.url}:${item.line} |\n`;
    }

    // Identify patterns
    const lodashMergeIssues = worseAll.filter(x => 
        x.url.includes('lodash') && 
        (x.func.includes('Merge') || x.func.includes('merge') || x.func.includes('Assign') || x.func.includes('assign'))
    );

    const redisIssues = worseAll.filter(x => x.url.includes('redis') || x.url.includes('Redis'));

    md += `
---

## 🔍 Pattern Analysis

### Lodash Merge Operations
`;

    if (lodashMergeIssues.length > 0) {
        const totalLodashIncrease = lodashMergeIssues.reduce((sum, x) => sum + x.pctDiff, 0);
        md += `
**Total CPU increase from lodash merge operations: ${totalLodashIncrease.toFixed(2)}%**

These functions are typically called by \`_.merge()\`, \`_.mergeWith()\`, or \`_.assign()\` operations:

| Function | % Diff | Status |
|----------|--------|--------|
`;
        for (const item of lodashMergeIssues) {
            md += `| \`${item.func}\` | +${item.pctDiff.toFixed(2)}% | ${item.isNew ? 'NEW' : 'Increased'} |\n`;
        }
    } else {
        md += `No significant lodash merge performance issues detected.\n`;
    }

    md += `
### Redis Operations
`;

    if (redisIssues.length > 0) {
        const totalRedisIncrease = redisIssues.reduce((sum, x) => sum + x.pctDiff, 0);
        md += `
**Total CPU change in Redis operations: ${totalRedisIncrease.toFixed(2)}%**

| Function | Location | % Diff |
|----------|----------|--------|
`;
        for (const item of redisIssues.slice(0, 10)) {
            md += `| \`${item.func}\` | ${item.url}:${item.line} | ${item.pctDiff > 0 ? '+' : ''}${item.pctDiff.toFixed(2)}% |\n`;
        }
    } else {
        md += `No significant Redis performance issues detected.\n`;
    }

    md += `
---

## 📋 Recommendations

Based on the analysis:

`;

    // Generate recommendations based on findings
    const recommendations = [];

    const topWorse = worseAll[0];
    if (topWorse && topWorse.pctDiff > 1) {
        recommendations.push(`1. **Investigate \`${topWorse.func}\` at ${topWorse.url}:${topWorse.line}** - This function has the largest CPU increase (+${topWorse.pctDiff.toFixed(2)}% of total CPU time).`);
    }

    if (lodashMergeIssues.length > 0) {
        const totalLodash = lodashMergeIssues.reduce((sum, x) => sum + x.pctDiff, 0);
        recommendations.push(`2. **Review lodash merge usage** - New or increased merge operations are consuming +${totalLodash.toFixed(2)}% CPU. Consider:
   - Using Object spread (\`{...obj}\`) for shallow copies
   - Avoiding deep merges on large objects
   - Caching merged results if inputs are stable`);
    }

    const jsonParseIssue = worseAll.find(x => x.url.includes('redisClient') && x.line === 242);
    if (jsonParseIssue) {
        recommendations.push(`3. **Optimize Redis JSON parsing** - The Redis get callback at line 242 shows ${jsonParseIssue.pctDiff.toFixed(2)}% CPU increase. Consider:
   - Reducing payload sizes stored in Redis
   - Using MessagePack or other binary formats instead of JSON
   - Implementing lazy parsing only when needed`);
    }

    const newFunctions = worseUser.filter(x => x.isNew && x.afterHits > 5);
    if (newFunctions.length > 0) {
        recommendations.push(`4. **New code paths detected** - The following functions appeared in "after" but not "before":
${newFunctions.slice(0, 5).map(x => `   - \`${x.func}\` at ${x.url}:${x.line}`).join('\n')}`);
    }

    for (const rec of recommendations) {
        md += rec + '\n\n';
    }

    md += `
---

## Raw Data

### Top 50 Functions by CPU Usage (After Profile)

| Rank | % | Samples | Function | Location |
|------|---|---------|----------|----------|
`;

    const afterSorted = Object.values(afterStats)
        .sort((a, b) => b.hitCount - a.hitCount)
        .slice(0, 50);

    let rank = 1;
    for (const item of afterSorted) {
        const pct = (item.hitCount / afterTotal * 100).toFixed(2);
        md += `| ${rank++} | ${pct}% | ${item.hitCount} | \`${item.func.substring(0, 40)}\` | ${item.url.replace('file:///usr/code/src/Backend/', '')}:${item.line} |\n`;
    }

    return md;
}

// ============================================================================
// Console Output
// ============================================================================

function printConsoleSummary() {
    const beforeTotal = getTotalHits(before);
    const afterTotal = getTotalHits(after);

    const beforeStats = aggregateByFunction(before);
    const afterStats = aggregateByFunction(after);

    const comparison = compareProfiles(beforeStats, afterStats, beforeTotal, afterTotal);
    const worse = comparison.filter(x => x.pctDiff > 0.05).sort((a, b) => b.pctDiff - a.pctDiff);

    console.log('\n' + '='.repeat(120));
    console.log('CPU PROFILE COMPARISON SUMMARY');
    console.log('='.repeat(120));
    console.log(`Before: ${beforeTotal} samples, After: ${afterTotal} samples`);
    console.log(`Change: ${afterTotal - beforeTotal} samples (${((afterTotal - beforeTotal) / beforeTotal * 100).toFixed(1)}%)`);
    console.log('\n' + '-'.repeat(120));
    console.log('FUNCTIONS THAT GOT WORSE (normalized by total samples):');
    console.log('-'.repeat(120));
    console.log('% Diff | Before % | After % | Before# | After# | Function | Location');
    console.log('-'.repeat(120));

    for (const item of worse.slice(0, 30)) {
        const status = item.isNew ? ' [NEW]' : '';
        console.log(
            item.pctDiff.toFixed(2).padStart(6) + ' | ' +
            item.beforePct.toFixed(2).padStart(8) + ' | ' +
            item.afterPct.toFixed(2).padStart(7) + ' | ' +
            String(item.beforeHits).padStart(7) + ' | ' +
            String(item.afterHits).padStart(6) + ' | ' +
            item.func.substring(0, 30).padEnd(30) + ' | ' +
            item.url + ':' + item.line + status
        );
    }
}

// ============================================================================
// Main
// ============================================================================

console.log('\nAnalyzing CPU profiles...\n');

// Print console summary
printConsoleSummary();

// Generate markdown report
const report = generateMarkdownReport();
const outputPath = path.resolve(outputFile);
fs.writeFileSync(outputPath, report);

console.log('\n' + '='.repeat(120));
console.log(`Report saved to: ${outputPath}`);
console.log('='.repeat(120) + '\n');
