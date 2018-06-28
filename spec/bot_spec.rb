# frozen_string_literal: true

require "spec_helper"
require "configuration/jira"
require "bot"

describe Bot do
  let(:action)             { "created" }
  let(:title)              { "[#LIEF-123] Cure World Hunger!" }
  let(:comment)            { "I did it!" }
  let(:repo)               { "foo/bar" }
  let(:author)             { "jonhue" }
  let(:pr_number)          { 23 }
  let(:comment_id)         { 12345 }
  let(:jira_transition_id) { nil }

  let(:jira_configuration) do
    Configuration::Jira.new(
      project_key: "FOO",
      issue_type: "Story",
      transition_id: jira_transition_id
    )
  end

  let(:bot) do
    described_class.new(
      repo: repo,
      magic_qa_keyword: "QA:",
      max_description_chars: 600,
      component_map: { "repo": "component" },
      bot_github_login: "bot-user",
      jira_configuration: jira_configuration
    )
  end

  describe "#extract_issue_id" do
    subject(:issue_id) { bot.extract_issue_id(title) }

    context "when title contains properly formatted issue" do
      it "returns the issue id" do
        expect(issue_id).to eq "LIEF-123"
      end
    end

    context "when title contains no proper issue id" do
      let(:title) { "Title without issue id" }

      it "returns nil" do
        expect(issue_id).to eq nil
      end
    end
  end

  describe "#handle_comment" do
    subject(:handle_comment) do
      bot.handle_comment(
        action: action,
        title: title,
        comment: comment,
        pr_number: pr_number,
        author: author,
        comment_id: comment_id
      )
    end

    context "when bot created comment" do
      let(:author) { "bot-user" }

      it "does not create jira comment" do
        expect(Jira::Comment).not_to receive(:create)
        handle_comment
      end
    end

    context "when linked issue exists" do
      before do
        allow(Jira::Issue).to receive(:find).and_return double(key: "LIEF-123")
      end

      context "when comment starts with QA:" do
        let(:comment) { "QA: foo" }

        it "creates a jira comment with the rest of the comment and adds a reaction to the comment" do
          expect(Jira::Comment).to receive(:create).with("LIEF-123", "foo")
          expect(Github::Reaction).to receive(:create)
          handle_comment
        end
      end

      context "with multiline QA comments" do
        let(:comment) { "foo\nbar\nbaz QA: this\nis\na\nmultiline\ncomment" }

        it "uses all lines" do
          expect(Jira::Comment).to receive(:create).with("LIEF-123", "this\nis\na\nmultiline\ncomment")
          expect(Github::Reaction).to receive(:create)
          handle_comment
        end
      end

      context "when comment has QA: in the middle" do
        let(:comment) { "bar baz QA: foo" }

        it "creates a jira comment with the rest of the comment" do
          expect(Jira::Comment).to receive(:create).with("LIEF-123", "foo")
          expect(Github::Reaction).to receive(:create)
          handle_comment
        end
      end

      context "with unrelated comment" do
        let(:comment) { "Nice weather isn't it?" }

        it "does not create a jira comment or a github reaction" do
          expect(Jira::Comment).not_to receive(:create)
          expect(Github::Reaction).not_to receive(:create)
          handle_comment
        end
      end

      context "with empty QA comment" do
        let(:comment) { "QA:" }

        it "does not create a jira comment or a github reaction" do
          expect(Jira::Comment).not_to receive(:create)
          expect(Github::Reaction).not_to receive(:create)
          handle_comment
        end
      end

      context "when the comment is edited" do
        let(:comment) { "QA: foo" }
        let(:action) { "edit" }

        it "does not create a jira comment or a github reaction" do
          expect(Jira::Comment).not_to receive(:create)
          expect(Github::Reaction).not_to receive(:create)
          handle_comment
        end
      end
    end

    context "when linked issue doesn't exist" do
      let(:comment) { "QA: foo" }

      before do
        allow(Jira::Issue).to receive(:find).and_return nil
      end

      it "creates the issue and renames the github PR" do
        expect(Jira::Issue).to receive(:create).and_return(double(key: "LIEF-123"))
        expect(Jira::Comment).to receive(:create).with("LIEF-123", "foo")
        expect(Github::PullRequest).to receive(:update_title)
        expect(Github::Reaction).to receive(:create)
        handle_comment
      end

      context "when jira_transition_id is set" do
        let(:jira_transition_id) { "foo_123" }

        it "creates the issue and renames the github PR" do
          expect(Jira::Issue).to receive(:create).and_return(double(key: "LIEF-123"))
          expect(Jira::Issue).to receive(:transition).with(anything, "foo_123")
          expect(Jira::Comment).to receive(:create).with("LIEF-123", "foo")
          expect(Github::PullRequest).to receive(:update_title)
          expect(Github::Reaction).to receive(:create)
          handle_comment
        end
      end

      context "with unrelated comment" do
        let(:comment) { "Nice weather isn't it?" }

        it "does not create a jira ticket, or comment or a github reaction" do
          expect(Jira::Issue).not_to receive(:create)
          expect(Jira::Issue).not_to receive(:transition)
          expect(Jira::Comment).not_to receive(:create)
          expect(Github::Reaction).not_to receive(:create)
          handle_comment
        end
      end
    end
  end

  describe "#handle_pull_request" do
    subject(:handle_pull_request) { bot.handle_pull_request(action: "opened", title: title, pr_number: pr_number) }

    context "when linked issue exists" do
      it "adds issue URL and description to GitHub when description exists" do
        allow(Jira::Issue).to(
          receive(:find).and_return(
            double(attrs: { "fields" => { "description" => "test" }, "url" => "https://liefery.atlassian.net/browse/LIEF-123" })
          )
        )
        expect(Github::Comment).to(
          receive(:create).with("foo/bar", 23, "test\n\nhttps://liefery.atlassian.net/browse/LIEF-123")
        )
        handle_pull_request
      end

      it "only adds URL to GitHub when description does not exist" do
        allow(Jira::Issue).to(
          receive(:find).and_return(
            double(attrs: { "fields" => { "description" => nil }, "url" => "https://liefery.atlassian.net/browse/LIEF-123" })
          )
        )
        expect(Github::Comment).to(
          receive(:create).with("foo/bar", 23, "https://liefery.atlassian.net/browse/LIEF-123")
        )
        handle_pull_request
      end
    end

    context "when linked issue doesn't exist" do
      it "returns nil" do
        allow(Jira::Issue).to receive(:find).and_return nil
        expect(Github::Comment).not_to receive(:create)
        expect(handle_pull_request).to eq(nil)
      end
    end
  end
end