# Sequential Thinking — Structured Reasoning

## Description
Structured reasoning skill for complex multi-step problems.
Replaces the sequential-thinking MCP server.

## When to Use
- Complex architectural decisions
- Multi-step problem solving
- Debugging with multiple hypotheses
- Planning with dependencies and trade-offs

## Method

### Step 1: Problem Definition
- What exactly is the problem?
- What are the constraints?
- What does success look like?

### Step 2: Decomposition
- Break the problem into sub-problems
- Identify dependencies between sub-problems
- Order by priority and dependency

### Step 3: Hypothesis Generation
For each sub-problem:
- Generate 2-3 possible approaches
- List pros/cons of each
- Identify unknowns that need investigation

### Step 4: Investigation
- Test hypotheses with concrete actions (read files, run commands, search)
- Gather evidence before deciding

### Step 5: Synthesis
- Combine findings into a coherent solution
- Validate against the original problem
- Identify remaining risks

## Notes
- For truly complex problems, use sub-agents to parallelize investigation
- Document your reasoning chain for transparency
