module Aws
  module S3

    # Provides an encryption client that encrypts and decrypts data client-side,
    # storing the encrypted data in Amazon S3.
    #
    # This client uses a process called "envelope encryption". Your private
    # encryption keys and your data's plain-text are **never** sent to
    # Amazon S3. **If you loose you encrption keys, you will not be able to
    # un-encrypt your data.**
    #
    # ## Envelope Encryption Overview
    #
    # The goal of envelope encryption is to combine the performance of
    # fast symmetric encryption while maintaining the secure key management
    # that asymmetric keys provide.
    #
    # A one-time-use symmetric key (envelope key) is generated client-side.
    # This is used to encrypt the data client-side. This key is then
    # encrypted by your master key and stored alongside your data in Amazon
    # S3.
    #
    # When accessing your encrypted data with the encryption client,
    # the encrypted envelope key is retrieved and decrypted client-side
    # with your master key. The envelope key is then used to decrypt the
    # data client-side.
    #
    # One of the benefits of envelope encryption is that if your master key
    # is compromised, you have the option of jut re-encrypting the stored
    # envelope symmetric keys, instead of re-encrypting all of the
    # data in your account.
    #
    # ## Basic Usage
    #
    # The encryption client requires an {Aws::S3::Client}. If you do not
    # provide a `:client`, then a client will be constructed for you.
    #
    #     require 'openssl'
    #     key = OpenSSL::PKey::RSA.new(1024)
    #
    #     # encryption client
    #     s3 = Aws::S3::Encryption::Client.new(encryption_key: key)
    #
    #     # round-trip an object, encrypted/decrypted locally
    #     s3.put_object(bucket:'aws-sdk', key:'secret', body:'handshake')
    #     s3.get_object(bucket:'aws-sdk', key:'secret').body.read
    #     #=> 'handshake'
    #
    #     # reading encrypted object without the encryption client
    #     # results in the getting the cipher text
    #     Aws::S3::Client.new.get_object(bucket:'aws-sdk', key:'secret').body.read
    #     #=> "... cipher text ..."
    #
    # ## Keys
    #
    # For client-side encryption to work, you must provide an encryption key:
    #
    #     key = OpenSSL::Cipher.new("AES-256-ECB").random_key # symmetric key
    #     key = OpenSSL::PKey::RSA.new(1024) # asymmetric key pair
    #
    #     s3 = Aws::S3::Encryption::Client.new(encryption_key: key)
    #
    # Alternatively, you can use a {KeyProvider}. A key provider makes
    # it easy to work with multiple keys and simplifies key rotation.
    #
    # ### Key Provider
    #
    # A {KeyProvider} is any object that responds to:
    #
    # * `#encryption_materials`
    # * `#key_for(materials_description)`
    #
    # Here is a trivial implementation of an in-memory key provider.
    # This is provided as a demonstration of the key provider interface,
    # and should not be used in production:
    #
    #     class KeyProvider
    #
    #       def initialize(default_key_name, keys)
    #         @keys = keys
    #         @encryption_materials = Aws::S3::Encryption::Materials.new(
    #           key: @keys[default_key_name],
    #           description: MultiJson.dump(key: default_key_name),
    #         )
    #       end
    #
    #       attr_reader :encryption_materials
    #
    #       def key_for(matdesc)
    #         key_name = MultiJson.load(matdesc)['key']
    #         if key = @keys[key_name]
    #           key
    #         else
    #           raise "encryption key not found for: #{matdesc.inspect}"
    #         end
    #       end
    #     end
    #
    # Given the above key provider, you can create an encryption client that
    # chooses the key to use based on the materials description stored with
    # the encrypted object. This makes it possible to use multiple keys
    # and simplifies key rotation.
    #
    #     # uses "new-key" for encrypting objects, uses either for decrypting
    #     keys = KeyProvider.new('new-key', {
    #       "old-key" => Base64.decode64("kM5UVbhE/4rtMZJfsadYEdm2vaKFsmV2f5+URSeUCV4="),
    #       "new-key" => Base64.decode64("w1WLio3agRWRTSJK/Ouh8NHoqRQ6fn5WbSXDTHjXMSo="),
    #     }),
    #
    #     # chooses the key based on the materials description stored
    #     # with the encrypted object
    #     s3 = Aws::S3::Encryption::Client.new(key_provider: keys)
    #
    # ## Materials Description
    #
    # A materials description is JSON document string that is stored
    # in the metadata (or instruction file) of an encrypted object.
    # The {DefaultKeyProvider} uses the empty JSON document `"{}"`.
    #
    # When building a key provider, you are free to store whatever
    # information you need to identify the master key that was used
    # to encrypt the object.
    #
    # ## Envelope Location
    #
    # By default, the encryption client store the encryption envelope
    # with the object, as metadata. You can choose to have the envelope
    # stored in a separate "instruction file". An instruction file
    # is an object, with the key of the encrypted object, suffixed with
    # `".instruction"`.
    #
    # Specify the `:envelope_location` option as `:instruction_file` to
    # use an instruction file for storing the envelope.
    #
    #     # default behavior
    #     s3 = Aws::S3::Encryption::Client.new(
    #       key_provider: ...,
    #       envelope_location: :metadata,
    #     )
    #
    #     # store envelope in a separate object
    #     s3 = Aws::S3::Encryption::Client.new(
    #       key_provider: ...,
    #       envelope_location: :instruction_file,
    #       instruction_file_suffix: '.instruction' # default
    #     )
    #
    # When using an instruction file, multiple requests are made when
    # putting and getting the object. **This may cause issues if you are
    # issuing concurrent PUT and GET requests to an encrypted object.**
    #
    module Encryption

      class Client

        # Creates a new encryption client. You must provide on of the following
        # options:
        #
        # * `:key_provider`
        # * `:encryption_key`
        #
        # @option opitons [S3::Client] :client A basic S3 client that is used
        #   to make api calls. If a `:client` is not provided, a new {S3::Client}
        #   will be constructed.
        #
        # @option options [#key_for] :key_provider Any object that responds
        #   to `#key_for`. This method should accept a materials description
        #   JSON document string and return return an encryption key.
        #
        # @option options [OpenSSL::PKey::RSA, String] :encryption_key The master
        #   key to use for encrypting/decrypting all objects.
        #
        # @option options [Symbol] :envelope_location (:metadata) Where to
        #   store the envelope encryption keys. By default, the envelope is
        #   stored with the encrypted object. If you pass `:instruction_file`,
        #   then the envelope is stored in a seperate object in Amazon S3.
        #
        # @option options [String] :instruction_file_suffix ('.instruction')
        #   When `:envelope_location` is `:instruction_file` then the
        #   instruction file uses the object key with this suffix appended.
        #
        def initialize(options = {})
          @client = options[:client] || S3::Client.new
          @key_provider = extract_key_provider(options)
          @envelope_location = extract_location(options)
          @instruction_file_suffix = extract_suffix(options)
        end

        # @return [S3::Client]
        attr_reader :client

        # @return [KeyProvider]
        attr_reader :key_provider

        # @return [Symbol<:metadata, :instruction_file>]
        attr_reader :envelope_location

        # @return [String] When {#envelope_location} is `:instruction_file`,
        #   the envelope is stored in the object with the object key suffixed
        #   by this string.
        attr_reader :instruction_file_suffix

        # Uploads an object to Amazon S3, encrypting data client-side.
        # See {S3::Client#put_object} for documentation on accepted
        # request parameters.
        # @option (see S3::Client#put_object)
        # @return (see S3::Client#put_object)
        # @see S3::Client#put_object
        def put_object(params = {})
          req = @client.build_request(:put_object, params)
          req.handlers.add(EncryptHandler, priority: 95)
          req.context[:encryption] = {
            materials: @key_provider.encryption_materials,
            envelope_location: @envelope_location,
            instruction_file_suffix: @instruction_file_suffix,
          }
          req.send_request
        end

        # Gets an object from Amazon S3, decrypting  data locally.
        # See {S3::Client#get_object} for documentation on accepted
        # request parameters.
        # @option params [String] :instruction_file_suffix The suffix
        #   used to find the instruction file containing the encryption
        #   envelope. You should not set this option when the envelope
        #   is stored in the object metadata. Defaults to
        #   {#instruction_file_suffix}.
        # @option params [String] :instruction_file_suffix
        # @option (see S3::Client#get_object)
        # @return (see S3::Client#get_object)
        # @see S3::Client#get_object
        # @note The `:range` request parameter is not yet supported.
        def get_object(params = {}, &block)
          if params[:range]
            raise NotImplementedError, '#get_object with :range not supported yet'
          end
          envelope_location, instruction_file_suffix = envelope_options(params)
          req = @client.build_request(:get_object, params)
          req.handlers.add(DecryptHandler)
          req.context[:encryption] = {
            key_provider: @key_provider,
            envelope_location: envelope_location,
            instruction_file_suffix: instruction_file_suffix,
          }
          req.send_request(target: block)
        end

        private

        def envelope_options(params)
          location = params.delete(:envelope_location) || @envelope_location
          suffix = params.delete(:instruction_file_suffix)
          if suffix
            [:instruction_file, suffix]
          else
            [location, @instruction_file_suffix]
          end
        end

        def extract_key_provider(options)
          if options[:key_provider]
            options[:key_provider]
          elsif options[:encryption_key]
            DefaultKeyProvider.new(options)
          else
            msg = "you must pass a :key_provider or :encryption_key"
            raise ArgumentError, msg
          end
        end

        def extract_location(options)
          location = options[:envelope_location] || :metadata
          if [:metadata, :instruction_file].include?(location)
            location
          else
            msg = ":envelope_location must be :metadata or :instruction_file "
            msg << "got #{location.inspect}"
            raise ArgumentError, msg
          end
        end

        def extract_suffix(options)
          suffix = options[:instruction_file_suffix] || '.instruction'
          if String === suffix
            suffix
          else
            msg = ":instruction_file_suffix must be a String"
            raise ArgumentError, msg
          end
        end

      end
    end
  end
end
