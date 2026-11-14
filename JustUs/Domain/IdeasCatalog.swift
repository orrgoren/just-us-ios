import Foundation

enum IdeasCatalog {
  static func load(bundle: Bundle = .main) -> [DateIdea] {
    guard let url = bundle.url(forResource: "ideas", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let ideas = try? JSONDecoder().decode([DateIdea].self, from: data) else {
      return []
    }
    return ideas
  }

  static func idea(_ id: String, in ideas: [DateIdea]) -> DateIdea? {
    ideas.first { $0.id == id }
  }

  static func plan(from idea: DateIdea, notes: String?) -> FullPlan {
    FullPlan(
      ideaId: idea.id,
      title: idea.title,
      emoji: idea.emoji,
      summary: idea.summary,
      prep: idea.prep,
      twist: idea.twist,
      question: idea.question,
      durationLabel: idea.duration,
      costLabel: idea.cost,
      mood: idea.mood,
      location: idea.loc,
      privateNotes: notes
    )
  }
}
