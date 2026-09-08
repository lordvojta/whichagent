// Play the agent notification hits for opencode.
//
// opencode has no single "plan finished" event, but it does tell us which agent
// produced a message, and `plan` is one of its built in agents. So we remember
// the agent per session from chat.message, and when the session goes idle we
// pick the plan hit if that session was planning and the done hit otherwise.

import { spawn } from "node:child_process"
import os from "node:os"
import path from "node:path"

const SCRIPT = path.join(os.homedir(), ".claude", "hooks", "agent-sound.sh")
const agentBySession = new Map()

function play(event) {
  try {
    spawn(SCRIPT, [event, "opencode"], { stdio: "ignore", detached: true }).unref()
  } catch {
    // A missing sound must never take the editor down with it.
  }
}

function sessionIdOf(event) {
  const p = event?.properties ?? {}
  return p.sessionID ?? p.info?.sessionID ?? p.info?.id ?? p.sessionId
}

export const AgentSound = async () => {
  play("warm") // open the audio device early so the first real hit is instant

  return {
    "chat.message": async (input) => {
      if (input?.sessionID && input?.agent) {
        agentBySession.set(input.sessionID, input.agent)
      }
    },

    event: async ({ event }) => {
      switch (event?.type) {
        case "session.idle": {
          const agent = agentBySession.get(sessionIdOf(event))
          play(agent === "plan" ? "plan" : "done")
          break
        }
        case "permission.ask":
          play("input")
          break
      }
    },
  }
}
