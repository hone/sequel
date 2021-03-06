require 'oci8'
Sequel.require 'adapters/shared/oracle'

module Sequel
  module Oracle
    class Database < Sequel::Database
      include DatabaseMethods
      set_adapter_scheme :oracle

      # ORA-00028: your session has been killed
      # ORA-01012: not logged on
      # ORA-03113: end-of-file on communication channel
      # ORA-03114: not connected to ORACLE
      CONNECTION_ERROR_CODES = [ 28, 1012, 3113, 3114 ]      
      
      def connect(server)
        opts = server_opts(server)
        if opts[:database]
          dbname = opts[:host] ? \
            "//#{opts[:host]}#{":#{opts[:port]}" if opts[:port]}/#{opts[:database]}" : opts[:database]
        else
          dbname = opts[:host]
        end
        conn = OCI8.new(opts[:user], opts[:password], dbname, opts[:privilege])
        conn.autocommit = true
        conn.non_blocking = true
        conn
      end
      
      def dataset(opts = nil)
        Oracle::Dataset.new(self, opts)
      end

      def schema_parse_table(table, opts={})
        ds = dataset
        ds.identifier_output_method = :downcase
        schema, table = schema_and_table(table)
        table_schema = []
        metadata = transaction(opts){|conn| conn.describe_table(table.to_s)}
        metadata.columns.each do |column|
          table_schema << [
            column.name.downcase.to_sym,
            {
              :type => column.data_type,
              :db_type => column.type_string.split(' ')[0],
              :type_string => column.type_string,
              :charset_form => column.charset_form,
              :char_used => column.char_used?,
              :char_size => column.char_size,
              :data_size => column.data_size,
              :precision => column.precision,
              :scale => column.scale,
              :fsprecision => column.fsprecision,
              :lfprecision => column.lfprecision,
              :allow_null => column.nullable?
            }
          ]
        end
        table_schema
      end

      def execute(sql, opts={})
        synchronize(opts[:server]) do |conn|
          begin
            r = log_yield(sql){conn.exec(sql)}
            yield(r) if block_given?
            r
          rescue OCIException => e
            raise_error(e, :disconnect=>CONNECTION_ERROR_CODES.include?(e.code))
          end
        end
      end
      alias_method :do, :execute

      private
      
      def begin_transaction(conn)
        log_yield(TRANSACTION_BEGIN){conn.autocommit = false}
        conn
      end
      
      def commit_transaction(conn)
        log_yield(TRANSACTION_COMMIT){conn.commit}
      end

      def disconnect_connection(c)
        c.logoff
      end
      
      def remove_transaction(conn)
        conn.autocommit = true if conn
        super
      end
      
      def rollback_transaction(conn)
        log_yield(TRANSACTION_ROLLBACK){conn.rollback}
      end
    end
    
    class Dataset < Sequel::Dataset
      include DatasetMethods

      def fetch_rows(sql, &block)
        execute(sql) do |cursor|
          begin
            @columns = cursor.get_col_names.map{|c| output_identifier(c)}
            while r = cursor.fetch
              row = {}
              r.each_with_index {|v, i| row[@columns[i]] = v unless @columns[i] == :raw_rnum_}
              yield row
            end
          ensure
            cursor.close
          end
        end
        self
      end

      private

      def literal_other(v)
        case v
        when OraDate
          literal(Sequel.database_to_application_timestamp(v))
        else
          super
        end
      end
    end
  end
end
