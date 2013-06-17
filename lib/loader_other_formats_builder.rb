module LoaderOtherFormatsBuilder
  def self.included(base)
    base.class_eval do
      def link_to(name, options={})
        unless name == 'XML'
          url = { :format => name.to_s.downcase }.merge(options.delete(:url) || {}).except('page')
        else
          url = { :controller => 'loader', :action => 'export', :query_id => options[:query_id] }
        end
        caption = options.delete(:caption) || name
        html_options = { :class => name.to_s.downcase, :rel => 'nofollow' }.merge(options)
        @view.content_tag('span', @view.link_to(caption, url, html_options))
      end
    end
  end
end
