module ActiveRecord
  module ModelTranslations
    module ClassMethods
      def translates(*options)
        options = options.first
        add_translation_model_and_logic(options) unless included_modules.include?(InstanceMethods)
        add_translatable_attributes
      end

      def missing_translations(language = I18n.locale)
        translation_class = get_translation_class
        all( :joins => :model_translations,
             :conditions => ["#{self.quoted_table_name}.#{connection.quote_column_name('id')} NOT IN (SELECT #{self.name.underscore+'_id'} FROM #{translation_class.quoted_table_name} WHERE locale = ?)", language.to_s])
      end
      
      def validates_uniqueness_translation_of(*attr_names)
        configuration = { :case_sensitive => true }
        configuration.update(attr_names.extract_options!)
        
        validates_each(attr_names) do |record, attr_name, value|
          translation_class = Object.const_get "#{record.class.name}Translation"

          if record.translated_methods.include?(attr_name)
            column = translation_class.columns_hash[attr_name.to_s]
            sql_table_name = translation_class.quoted_table_name
            sql_column_name = translation_class.connection.quote_column_name(attr_name)
          else
            column = self.columns_hash[attr_name.to_s]
            sql_table_name = self.quoted_table_name
            sql_column_name = self.connection.quote_column_name(attr_name)
          end
          
          if value.nil?
            comparison_operator = "IS ?"
          elsif column.text?
            comparison_operator = "#{connection.case_sensitive_equality_operator} ?"
            value = column.limit ? value.to_s[0, column.limit] : value.to_s
          else
            comparison_operator = "= ?"
          end
          
          sql_attribute = "#{sql_table_name}.#{sql_column_name}"
          
          if value.nil? || (configuration[:case_sensitive] || !column.text?)
            condition_sql = "#{sql_attribute} #{comparison_operator}"
            condition_params = [value]
          else
            condition_sql = "LOWER(#{sql_attribute}) #{comparison_operator}"
            condition_params = [value.mb_chars.downcase]
          end
          
          if scope = configuration[:scope]
            Array(scope).map do |scope_item|
              scope_value = self.send(scope_item)
              condition_sql << " AND " << attribute_condition("#{record.class.quoted_table_name}.#{scope_item}", scope_value)
              condition_params << scope_value
            end
          end
          
          unless record.new_record?
            condition_sql << " AND #{record.class.quoted_table_name}.#{record.class.primary_key} <> ?"
            condition_params << record.send(:id)
          end
          
          if record.translated_methods.include?(attr_name)
            condition_sql << " AND #{sql_table_name}.locale = ?"
            condition_params << I18n.locale.to_s
            with_exclusive_scope(:find => { :include => :model_translations }) do
              if exists?([condition_sql, *condition_params])
                record.errors.add(attr_name, :taken, :default => configuration[:message], :value => value)
              end
            end
          else
            with_exclusive_scope do
              if exists?([condition_sql, *condition_params])
                record.errors.add(attr_name, :taken, :default => configuration[:message], :value => value)
              end
            end
          end

        end

      end

      private
      def get_translation_class
        Object.const_get("#{self.to_s}Translation")
      end
      
      def add_translation_model_and_logic(options)
        type = self.to_s.underscore
        translation_class_name = "#{self.to_s}Translation"
        
        translation_class = Class.new(ActiveRecord::Base) {
          belongs_to type.to_sym
          options[:belongs_to].each { |item|
            belongs_to item
          } unless options.nil? && options[:belongs_to].nil?
        }
        
        Object.const_set(translation_class_name, translation_class)

        include InstanceMethods

        has_many :model_translations, :class_name => translation_class_name, :dependent => :delete_all , :order => 'created_at desc'
        after_save :update_translations!
      end

      def add_translatable_attributes
        attributes = get_translation_class.column_names.reject{|item| item =~ /_id$|^id$|^locale$|_at$/ }
        attributes_belong_to = get_translation_class.column_names.select{|item| item =~ /_id$/ }.reject{|item| item =~ /^#{self.name.underscore+'_id'}$/ }
        attributes += attributes_belong_to.map{|item| item = item[0..-4]}
        
        attributes = attributes.collect{ |attribute| attribute.to_sym }
        attributes.each do |attribute|
          define_method "#{attribute}=" do |value|
            translated_attributes[attribute] = value
          end
          
          define_method 'translated_methods' do
            attributes
          end

          define_method attribute do
            return translated_attributes[attribute] if translated_attributes[attribute]
            return nil if new_record?

            translation = model_translations.detect { |t| t.locale == I18n.locale.to_s } ||
                          model_translations.detect { |t| t.locale == I18n.default_locale.to_s } ||
                          model_translations.first
            translation ? (translation[attribute] ? translation[attribute] : translation.send(attribute)) : nil
          end
        end
      end

    end

    module InstanceMethods
      def translated_attributes
        @translated_attributes ||= {}
      end

      def update_translations!
        return if translated_attributes.blank?
        translation = model_translations.find_or_initialize_by_locale(I18n.locale.to_s)
        translation.attributes = translation.attributes.merge(translated_attributes)
        translation.save!
      end
    
      def translated_locales
        model_translations.to_a.map { |x| x.locale }
      end
    end
  end
end
