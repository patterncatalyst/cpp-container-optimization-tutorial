source "https://rubygems.org"

# GitHub Pages bundle keeps everything Pages-compatible in one go.
# https://pages.github.com/versions/
gem "github-pages", group: :jekyll_plugins

group :jekyll_plugins do
  gem "jekyll-feed"
  gem "jekyll-seo-tag"
  gem "jekyll-sitemap"
  gem "jekyll-redirect-from"
end

# Lock http_parser.rb to v0.6.x on JRuby; otherwise no-op.
gem "http_parser.rb", "~> 0.6.0", :platforms => [:jruby]
