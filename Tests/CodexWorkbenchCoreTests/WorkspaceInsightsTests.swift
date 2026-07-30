import CodexWorkbenchCore
import Foundation

func runWorkspaceInsightsTests(_ runner: inout TestRunner) {
    let json = #"""
    {
      "generated_at":"2026-07-17T08:00:00Z",
      "active_profile":"hd-master",
      "profiles":[],
      "project_rankings":{"available":true,"projects":[
        {"name":"small","path":"/safe/small","thread_count":1,"tokens_used":100,"latest_updated_at":2},
        {"name":"large","path":"/safe/large","thread_count":4,"tokens_used":900,"latest_updated_at":1}
      ]},
      "tool_rankings":{"available":true,"tools":[
        {"id":"a","namespace":"functions","name":"alpha","call_count":2,"latest_updated_at":1,"thread_tokens":500},
        {"id":"b","namespace":"functions","name":"beta","call_count":8,"latest_updated_at":2,"thread_tokens":200}
      ]},
      "skill_rankings":{"available":true,"skills":[
        {"name":"one","use_count":1,"latest_timestamp":null},
        {"name":"three","use_count":3,"latest_timestamp":"2026-07-17T07:00:00Z"}
      ],"bad_line_count":0}
    }
    """#
    let payload = try? AccountDashboardPayload.decode(data: Data(json.utf8))
    let insights = AccountPresentationBuilder.workspaceInsights(payload: payload)

    runner.expect(
        insights.projects.map(\.name) == ["large", "small"],
        "Projects should be ranked by token usage"
    )
    runner.expect(
        insights.tools.map(\.name) == ["beta", "alpha"],
        "Tools should be ranked by call count"
    )
    runner.expect(
        insights.skills.map(\.name) == ["three", "one"],
        "Skills should be ranked by observed use count"
    )
    runner.expect(insights.projectsAvailable, "Project availability should remain explicit")
    runner.expect(insights.toolsAvailable, "Tool availability should remain explicit")
    runner.expect(insights.skillsAvailable, "Skill availability should remain explicit")

    let unavailable = AccountPresentationBuilder.workspaceInsights(payload: nil)
    runner.expect(!unavailable.projectsAvailable, "Missing project data must not look like an empty success")
    runner.expect(!unavailable.toolsAvailable, "Missing tool data must not look like an empty success")
    runner.expect(!unavailable.skillsAvailable, "Missing skill data must not look like an empty success")
}
