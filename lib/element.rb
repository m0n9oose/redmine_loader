module Nokogiri
  module XML
    class Element
      def value_at(field_name, *options)
        at(field_name).try(:text).try(:send, *options)
      end
    end
  end
end
