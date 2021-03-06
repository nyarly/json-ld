module JSON::LD
  # Simple Ruby reflector class to provide native
  # access to JSON-LD objects
  class Resource
    # @!attribute [r] attributes
    # @return [Hash<String => Object] Object representation of resource
    attr_reader :attributes

    # @!attribute [r] id
    # @return [String] ID of this resource
    attr_reader :id

    # @!attribute [r] context
    # @return [JSON::LD::Context] Context associated with this resource
    attr_reader :context

    # Is this resource clean (i.e., saved to mongo?)
    #
    # @return [Boolean]
    def clean?; @clean; end

    # Is this resource dirty (i.e., not yet saved to mongo?)
    #
    # @return [Boolean]
    def dirty?; !clean?; end
    
    # Has this resource been reconciled against a mongo ID?
    #
    # @return [Boolean]
    def reconciled?; @reconciled; end

    # Has this resource been resolved so that
    # all references are to other Resources?
    #
    # @return [Boolean]
    def resolved?; @resolved; end

    # Anonymous resources have BNode ids or no schema:url
    #
    # @return [Boolean]
    def anonymous?; @anon; end

    # Is this a stub resource, which has not yet been
    # synched or created within the DB?
    def stub?; !!@stub; end

    # Is this a new resource, which has not yet been
    # synched or created within the DB?
    def new?; !!@new; end

    # Manage contexts used by resources.
    #
    # @param [String] ctx
    # @return [JSON::LD::Context]
    def self.set_context(ctx)
      (@@contexts ||= {})[ctx] = JSON::LD::Context.new.parse(ctx)
    end

    # A new resource from the parsed graph
    # @param [Hash{String => Object}] node_definition
    # @param [Hash{Symbol => Object}] options
    # @option options [String] :context
    #   Resource context, used for finding
    #   appropriate collection and JSON-LD context.
    # @option options [Boolean] :clean (false)
    # @option options [Boolean] :compact (false)
    #   Assume `node_definition` is in expanded form
    #   and compact using `context`.
    # @option options [Boolean] :reconciled (!new)
    #   node_definition is not based on Mongo IDs
    #   and must be reconciled against Mongo, or merged
    #   into another resource.
    # @option options [Boolean] :new (true)
    #   This is a new resource, not yet saved to Mongo
    # @option options [Boolean] :stub (false)
    #   This is a stand-in for another resource that has
    #   not yet been retrieved (or created) from Mongo
    def initialize(node_definition, options = {})
      @context_name = options[:context]
      @context = self.class.set_context(@context_name)
      @clean = options.fetch(:clean, false)
      @new = options.fetch(:new, true)
      @reconciled = options.fetch(:reconciled, !@new)
      @resolved = false
      @attributes = if options[:compact]
        JSON::LD::API.compact(node_definition, @context)
      else
        node_definition
      end
      @id = @attributes['@id']
      @anon = @id.nil? || @id.to_s[0,2] == '_:'
    end

    # Return a hash of this object, suitable for use by for ETag
    # @return [Fixnum]
    def hash
      self.deresolve.hash
    end

    # Reverse resolution of resource attributes.
    # Just returns `attributes` if
    # resource is unresolved. Otherwise, replaces `Resource`
    # values with node references.
    #
    # Result is expanded and re-compacted to get to normalized
    # representation.
    #
    # @return [Hash] deresolved attribute hash
    def deresolve
      node_definition = if resolved?
        deresolved = attributes.keys.inject({}) do |memo, prop|
          value = attributes[prop]
          memo[prop] = case value
          when Resource
            {'id' => value.id}
          when Array
            value.map do |v|
              v.is_a?(Resource) ? {'id' => v.id} : v
            end
          else
            value
          end
          memo
        end
        deresolved
      else
        attributes
      end

      compacted = nil
      JSON::LD::API.expand(node_definition, :expandContext => @context) do |expanded|
        compacted = JSON::LD::API.compact(expanded, @context)
      end
      compacted.delete_if {|k, v| k == '@context'}
    end

    # Serialize to JSON-LD, minus `@context` using
    # a deresolved version of the attributes
    #
    # @param [Hash] options
    # @return [String] serizlied JSON representation of resource
    def to_json(options = nil)
      deresolve.to_json(options)
    end

    # Update node references using the provided map.
    # This replaces node references with Resources,
    # either stub or instantiated.
    #
    # Node references with ids not in the reference_map
    # will cause stub resources to be added to the map.
    #
    # @param [Hash{String => Resource}] reference_map
    # @return [Resource] self
    def resolve(reference_map)
      return if resolved?
      def update_obj(obj, reference_map)
        case obj
        when Array
          obj.map {|o| update_obj(o, reference_map)}
        when Hash
          if obj.node_ref?
            reference_map[obj['id']] ||= Resource.new(obj,
              :context => @context_name,
              :clean => false,
              :stub => true
              )
          else
            obj.keys.each do |k|
              obj[k] = update_obj(obj[k], reference_map)
            end
            obj
          end
        else
          obj
        end
      end

      #$logger.debug "resolve(0): #{attributes.inspect}"
      @attributes.each do |k, v|
        next if %w(id type).include?(k)
        @attributes[k] = update_obj(@attributes[k], reference_map)
      end
      #$logger.debug "resolve(1): #{attributes.inspect}"
      @resolved = true
      self
    end

    # Merge resources
    # FIXME: If unreconciled or unresolved resources are merged
    # against reconciled/resolved resources, they will appear
    # to not match, even if they are really the same thing.
    #
    # @param [Resource] resource
    # @return [Resource] self
    def merge(resource)
      if attributes.neq?(resource.attributes)
        resource.attributes.each do |p, v|
          next if p == 'id'
          if v.nil? or (v.is_a?(Array) and v.empty?)
            attributes.delete(p)
          else
            attributes[p] = v
          end
        end
        @resolved = @clean = false
      end
      self
    end

    #
    # Override this method to implement save using
    # an appropriate storage mechanism.
    #
    # Save the object to the Mongo collection
    # use Upsert to create things that don't exist.
    # First makes sure that the resource is valid.
    #
    # @return [Boolean] true or false if resource not saved
    def save
      raise NotImplemented
    end

    # Access individual fields, from subject definition
    def property(prop_name); @attributes.fetch(prop_name, nil); end

    # Access individual fields, from subject definition
    def method_missing(method, *args)
      property(method.to_s)
    end

    def inspect
      "<Resource" +
      attributes.map do |k, v|
        "\n  #{k}: #{v.inspect}"
      end.join(" ") +
      ">"
    end
  end
end
