module JSONAPI
  module Utils
    module Response
      module Formatters
        # Helper method to format ActiveRecord or Hash objects into JSON API-compliant ones.
        #
        # @note The return of this method represents what will actually be displayed in the response body.
        # @note It can also be called as #jsonapi_serialize due to backward compatibility issues.
        #
        # @param object [ActiveRecord::Base, ActiveRecord::Relation, Hash, Array<Hash>]
        #   Object to be formatted into JSON
        #   e.g.: User.first, User.all, { data: { id: 1, first_name: 'Tiago' } },
        #   [{ data: { id: 1, first_name: 'Tiago' } }]
        #
        # @option options [JSONAPI::Resource] resource: it tells the formatter which resource
        #   class to be used rather than use an infered one (default behaviour)
        #
        # @option options [ActiveRecord::Base] model: ActiveRecord model class to be instantiated
        #   when a Hash or Array of Hashes is passed as the "object" argument
        #
        # @option options [Integer] count: if it's rendering a collection of resources, the default
        #   gem's counting method can be bypassed by the use of this options. It's shows then the total
        #   records resulting from that request and also calculates the pagination.
        #
        # @return [Hash]
        #
        # @api public
        def jsonapi_format(object, options = {})
          if object.is_a?(Hash)
            hash    = object.with_indifferent_access
            object = hash_to_active_record(hash[:data], options[:model])
          end
          fix_custom_request_options(object)
          build_response_document(object, options).contents
        end

        alias_method :jsonapi_serialize, :jsonapi_format

        # Helper method to format ActiveRecord or any object that responds to #errors
        # into JSON API-compliant error response bodies.
        #
        # @note The return of this method represents what will actually be displayed in the response body.
        # @note It can also be called as #jsonapi_serialize_errors due to backward compatibility issues.
        #
        # @param object [ActiveRecord::Base or any object that responds to #errors]
        #   Error object to be serialized into JSON
        #   e.g.: User.new(name: nil).tap(&:save), MyErrorDecorator.new(invalid_object)
        #
        # @return [Array]
        #
        # @api public
        def jsonapi_format_errors(object)
          if active_record_obj?(object)
            object = JSONAPI::Utils::Exceptions::ActiveRecord.new(object, @request.resource_klass, context) 
          end
          errors = object.respond_to?(:errors) ? object.errors : object
          JSONAPI::Utils::Support::Error.sanitize(errors).uniq
        end

        alias_method :jsonapi_serialize_errors, :jsonapi_format_errors

        private

        # Check whether the given object is an ActiveRecord-like one.
        #
        # @param object [Object] Object to be checked
        #
        # @return [TrueClass, FalseClass]
        #
        # @api private
        def active_record_obj?(object)
          defined?(ActiveRecord::Base) &&
            (object.is_a?(ActiveRecord::Base) ||
            object.singleton_class.include?(ActiveModel::Model))
        end

        # Build the full response document.
        #
        # @param object [ActiveRecord::Base, ActiveRecord::Relation, Hash, Array<Hash>]
        #   Object to be formatted into JSON
        #   e.g.: User.first, User.all, { data: { id: 1, first_name: 'Tiago' } },
        #   [{ data: { id: 1, first_name: 'Tiago' } }]
        #
        # @option options [JSONAPI::Resource] resource: it tells the builder which resource
        #   class to be used rather than use an infered one (default behaviour)
        #
        # @option options [Integer] count: if it's rendering a collection of resources, the default
        #   gem's counting method can be bypassed by the use of this options. It's shows then the total
        #   records resulting from that request and also calculates the pagination.
        #
        # @return [JSONAPI::ResponseDocument]
        #
        # @api private
        def build_response_document(object, options)
          results = JSONAPI::OperationResults.new

          if object.respond_to?(:to_ary)
            records = build_collection(object, options)
            results.add_result(JSONAPI::ResourcesOperationResult.new(:ok, records, result_options(object, options)))
          else
            record = turn_into_resource(object, options)
            results.add_result(JSONAPI::ResourceOperationResult.new(:ok, record))
          end

          @_response_document = create_response_document(results)
        end

        # Apply a proper action setup for custom requests/actions.
        #
        # @note The setup_(index|show)_action comes from JSONAPI::Resources' API.
        #
        # @param object [ActiveRecord::Base, ActiveRecord::Relation, Hash, Array<Hash>]
        #   It's checked whether this object refers to a collection or not.
        #
        # @api private
        def fix_custom_request_options(object)
          return unless custom_get_request_with_params?
          action = object.respond_to?(:to_ary) ? 'index' : 'show'
          @request.send("setup_#{action}_action", params)
        end

        # Check whether it's a custom GET request with params.
        #
        # @return [TrueClass, FalseClass]
        #
        # @api private
        def custom_get_request_with_params?
          request.method =~ /get/i && !%w(index show).include?(params[:action]) && !params.nil?
        end

        # Turn a collection of AR or Hash objects into a collection of JSONAPI::Resource ones.
        #
        # @param records [ActiveRecord::Relation, Hash, Array<Hash>]
        #   Objects to be instantiated as JSONAPI::Resource ones.
        #   e.g.: User.all, [{ data: { id: 1, first_name: 'Tiago' } }]
        #
        # @option options [JSONAPI::Resource] resource: it tells the buider which resource
        #   class to be used rather than use an infered one (default behaviour)
        #
        # @option options [Integer] count: if it's rendering a collection of resources, the default
        #   gem's counting method can be bypassed by the use of this options. It's shows then the total
        #   records resulting from that request and also calculates the pagination.
        #
        # @return [Array]
        #
        # @api private
        def build_collection(records, options)
          records = apply_filter(records, options)
          records = apply_sort(records)
          records = apply_pagination(records, options)
          records.respond_to?(:to_ary) ? records.map { |record| turn_into_resource(record, options) } : []
        end

        # Turn an AR or Hash object into a JSONAPI::Resource one.
        #
        # @param records [ActiveRecord::Relation, Hash, Array<Hash>]
        #   Object to be instantiated as a JSONAPI::Resource one.
        #   e.g.: User.first, { data: { id: 1, first_name: 'Tiago' } }
        #
        # @option options [JSONAPI::Resource] resource: it tells which resource
        #   class to be used rather than use an infered one (default behaviour)
        #
        # @return [JSONAPI::Resource]
        #
        # @api private
        def turn_into_resource(record, options)
          specified_resource = options[:resource]
          return @request.resource_klass.new(record, context) unless specified_resource
          specified_resource = specified_resource.call(record) if specified_resource.is_a?(Proc)
          specified_resource.to_s.constantize.new(record, context)
        end

        # Apply some result options like pagination params and record count to collection responses.
        #
        # @param records [ActiveRecord::Relation, Hash, Array<Hash>]
        #   Object to be formatted into JSON
        #   e.g.: User.all, [{ data: { id: 1, first_name: 'Tiago' } }]
        #
        # @option options [Integer] count: if it's rendering a collection of resources, the default
        #   gem's counting method can be bypassed by the use of this options. It's shows then the total
        #   records resulting from that request and also calculates the pagination.
        #
        # @return [Hash]
        #
        # @api private
        def result_options(records, options)
          {}.tap do |data|
            if JSONAPI.configuration.default_paginator != :none &&
              JSONAPI.configuration.top_level_links_include_pagination
              data[:pagination_params] = pagination_params(records, options)
            end

            if JSONAPI.configuration.top_level_meta_include_record_count
              data[:record_count] = record_count_for(records, options)
            end
          end
        end

        # Convert Hash or collection of Hashes into AR objects.
        #
        # @param data [Hash, Array<Hash>] Hash or collection to be converted
        #   e.g.: { data: { id: 1, first_name: 'Tiago' } },
        #         [{ data: { id: 1, first_name: 'Tiago' } }],
        #
        # @option options [ActiveRecord::Base] model: ActiveRecord model class to be
        #   used as base for the objects' intantialization.
        #
        # @return [ActiveRecord::Base, ActiveRecord::Relation]
        #
        # @api private
        def hash_to_active_record(data, model)
          return data if model.nil?
          coerced = [data].flatten.map { |hash| model.new(hash) }
          data.is_a?(Array) ? coerced : coerced.first
        rescue ActiveRecord::UnknownAttributeError
          if data.is_a?(Array)
            ids = data.map { |e| e[:id] }
            model.where(id: ids)
          else
            model.find_by(id: data[:id])
          end
        end
      end
    end
  end
end
