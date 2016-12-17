require "rails_helper"

RSpec.describe "POST /builds" do
  let(:payload) do
    File.read("spec/support/fixtures/pull_request_opened_event.json")
  end
  let(:parsed_payload) { JSON.parse(payload) }
  let(:repo_name) { parsed_payload["repository"]["full_name"] }
  let(:repo_id) { parsed_payload["repository"]["id"] }
  let(:pr_sha) { parsed_payload["pull_request"]["head"]["sha"] }
  let(:pr_number) { parsed_payload["number"] }

  context "with violations" do
    it "makes a new comment and cleans up resolved one" do
      filename = "spec/models/style_guide_spec.rb"
      existing_comment_violation = { line: 5, message: "Line is too long." }
      new_violation = { line: 9, message: "Trailing whitespace detected." }
      violations = [existing_comment_violation, new_violation]
      create(:repo, :active, github_id: repo_id, name: repo_name)
      stub_github_requests_with_violations(filename: filename)
      stub_commit_request(repo_name, pr_sha)
      stub_pull_request_comments_request(
        repo_name,
        pr_number,
        Hound::GITHUB_USERNAME,
      )
      stub_status_requests(repo_name, pr_sha)
      stub_review_job(RubocopReviewJob, violations: violations)
      review_request = stub_review_request(
        violations: [new_violation],
        file_path: filename,
      )

      post builds_path, payload: payload

      expect(review_request).to have_been_requested
    end
  end

  context "without violations" do
    it "does not make a comment" do
      create(:repo, github_id: repo_id, name: repo_name)
      stub_github_requests_with_no_violations
      review_request = stub_review_request

      post builds_path, payload: payload

      expect(review_request).not_to have_been_requested
    end
  end

  def stub_github_requests_with_no_violations
    stub_pull_request_files_request(repo_name, pr_number)
    stub_contents_request(
      repo_name: repo_name,
      sha: pr_sha,
      file: "file1.rb",
      fixture: "contents.json",
    )
    stub_contents_request(
      repo_name: repo_name,
      sha: pr_sha,
      file: ".hound.yml",
      fixture: "config_contents.json",
    )
  end

  def stub_github_requests_with_violations(filename:)
    stub_pull_request_files_request(repo_name, pr_number)
    stub_contents_request(
      repo_name: repo_name,
      sha: pr_sha,
      file: ".hound.yml",
      fixture: "config_contents.json",
    )
    stub_contents_request(
      repo_name: repo_name,
      sha: pr_sha,
      file: filename,
      fixture: "contents_with_violations.json",
    )
  end

  def stub_review_request(violations: [], file_path: "foo/bar.rb")
    url = "https://api.github.com/repos/#{repo_name}/pulls/#{pr_number}/reviews"
    comments = violations.map do |violation|
      { path: file_path, position: violation[:line], body: violation[:message] }
    end
    stub_request(:post, url).
      with(body: { event: "COMMENT", comments: comments }.to_json)
  end

  def stub_review_job(klass, violations:)
    allow(klass).to receive(:perform) do |attributes|
      CompleteFileReview.run(
        "commit_sha" => attributes.fetch("commit_sha"),
        "filename" => attributes.fetch("filename"),
        "linter_name" => attributes.fetch("linter_name"),
        "patch" => attributes.fetch("patch"),
        "pull_request_number" => attributes.fetch("pull_request_number"),
        "violations" => violations.map(&:stringify_keys),
      )
    end
  end
end
