require 'tensor_stream/evaluator/operation_helpers/random_gaussian'
require 'tensor_stream/math_gradients'

module TensorStream
  module Evaluator
    class FullEvalNotPossible < RuntimeError
    end

    # Errors during graph evaluation
    class EvaluatorExcecutionException < RuntimeError
      attr_reader :tensor

      def initialize(exception, tensor)
        @exception = exception
        @tensor = tensor
      end

      def wrapped_exception
        @exception
      end
    end

    ## PURE ruby evaluator used for testing and development
    class RubyEvaluator
      attr_accessor :retain

      include TensorStream::OpHelper

      def initialize(session, context, thread_pool: nil)
        @session = session
        @context = context
        @retain = context[:retain] || []
        @thread_pool = thread_pool || Concurrent::ImmediateExecutor.new
      end

      def run(tensor, execution_context)
        return tensor.map { |t| run(t, execution_context) } if tensor.is_a?(Array)

        return tensor if retain.include?(tensor) # if var is in retain don't eval to value

        child_context = execution_context.dup
        res = if tensor.is_a?(Operation)
                eval_operation(tensor, child_context)
              elsif tensor.is_a?(Variable)
                eval_variable(tensor, child_context)
              elsif tensor.is_a?(Placeholder)
                resolve_placeholder(tensor, child_context)
              else
                eval_tensor(tensor, child_context)
              end
        execution_context.deep_merge!(returns: child_context[:returns])
        res
      end

      def complete_eval(tensor, context)
        Kernel.loop do
          old_tensor = tensor
          tensor = run(tensor, context)

          tensor = tensor.map { |t| complete_eval(t, context) } if tensor.is_a?(Array) && !tensor.empty? && tensor[0].is_a?(Tensor)

          return tensor if old_tensor.equal?(tensor)
          return tensor unless tensor.is_a?(Tensor)
        end
      end

      protected

      def eval_variable(tensor, child_context)
        raise "variable #{tensor.name} not initalized" if tensor.value.nil?
        eval_tensor(tensor.value, child_context).tap do |val|
          child_context[:returns] ||= {}
          child_context[:returns][:vars] ||= []
          child_context[:returns][:vars] << { name: tensor.name, val: val }
        end
      end

      def eval_operation(tensor, child_context)
        return @context[tensor.name] if @context.key?(tensor.name)

        a = resolve_placeholder(tensor.items[0], child_context) if tensor.items && tensor.items[0]
        b = resolve_placeholder(tensor.items[1], child_context) if tensor.items && tensor.items[1]

        case tensor.operation
        when :argmax
          a = complete_eval(a, child_context)
          axis = tensor.options[:axis] || 0

          get_max_with_axis(a, axis, 0, tensor.data_type)
        when :cast
          a = complete_eval(a, child_context)

          call_op(:cast, a, child_context, ->(t, _b) { Tensor.cast_dtype(t, tensor.data_type) })
        when :sign
          a = complete_eval(a, child_context)

          func = lambda { |x, _b|
            if x.zero? || (x.is_a?(Float) && x.nan?)
              0
            elsif x < 0
              -1
            elsif x > 0
              1
            else
              raise 'assert: cannot be here'
            end
          }

          call_op(:sign, a, child_context, func)
        when :equal
          a = complete_eval(a, child_context)
          b = complete_eval(b, child_context)

          call_vector_op(:greater, a, b, child_context, ->(t, u) { t == u })
        when :not_equal
          a = complete_eval(a, child_context)
          b = complete_eval(b, child_context)

          call_vector_op(:not_equal, a, b, child_context, ->(t, u) { t != u })
        when :index
          f = run(a, child_context)
          index = run(b, child_context)

          f[index]
        when :slice
          input = complete_eval(a, child_context)
          start = complete_eval(b, child_context)
          size = complete_eval(tensor.options[:size], child_context)
          raise "start index and size not of the same shape #{start.size} != #{size.size}" if start.size != size.size
          slice_tensor(input, start, size)
        when :negate
          call_vector_op(:negate, a, nil, child_context, ->(t, _u) { -t })
        when :add
          call_vector_op(:add, a, b, child_context, ->(t, u) { t + u })
        when :sub
          call_vector_op(:sub, a, b, child_context, ->(t, u) { t - u })
        when :mul
          call_vector_op(:mul, a, b, child_context, ->(t, u) { t * u })
        when :pow
          call_vector_op(:pow, a, b, child_context, ->(t, u) { t**u })
        when :concat
          values = complete_eval(a, child_context)
          concat_array(values, tensor.options[:axis])
        when :abs
          call_op(:abs, a, child_context, ->(t, _b) { t.abs })
        when :tanh
          call_op(:tanh, a, child_context, ->(t, _b) { Math.tanh(t) })
        when :tan
          call_op(:tan, a, child_context, ->(t, _b) { Math.tan(t) })
        when :sec
          call_op(:sec, a, child_context, ->(t, _b) { Math.sec(t) })
        when :sin
          call_op(:sin, a, child_context, ->(t, _b) { Math.sin(t) })
        when :cos
          call_op(:cos, a, child_context, ->(t, _b) { Math.cos(t) })
        when :log
          call_op(:log, a, child_context, ->(t, _b) { t < 0 ? Float::NAN : Math.log(t) })
        when :exp
          call_op(:exp, a, child_context, ->(t, _b) { Math.exp(t) })
        when :sqrt
          call_op(:exp, a, child_context, ->(t, _b) { Math.sqrt(t) })
        when :square
          call_op(:square, a, child_context, ->(t, _b) { t * t })
        when :stop_gradient
          run(a, child_context)
        when :random_uniform
          maxval = tensor.options.fetch(:maxval, 1)
          minval = tensor.options.fetch(:minval, 0)

          generator = -> { rand * (maxval - minval) + minval }
          generate_vector(tensor.options[:shape], generator: generator)
        when :random_normal
          r = RandomGaussian.new(tensor.options.fetch(:mean), tensor.options.fetch(:stddev))
          generator = -> { r.rand }

          generate_vector(tensor.options[:shape], generator: generator)
        when :flow_group
          tensor.items.collect { |item| run(item, child_context) }
        when :assign
          assign = tensor.items[0] || tensor
          assign.value = complete_eval(tensor.items[1], child_context)
          assign.value
        when :assign_add
          tensor.items[0].value = process_vector_math_op(tensor.items[0], tensor.items[1], child_context, ->(t, u) { t + u })
          tensor.items[0].value
        when :assign_sub
          tensor.items[0].value = process_vector_math_op(tensor.items[0], tensor.items[1], child_context, ->(t, u) { t - u })
          tensor.items[0].value
        when :reduce_mean
          c = fp_type?(tensor.data_type) ? 0.0 : 0
          func = lambda { |v|
            if v.is_a?(Array)
              v.empty? ? c : (v.reduce(:+) / v.size)
            else
              v
            end
          }

          reduction(child_context, tensor, func)
        when :reduce_sum
          c = fp_type?(tensor.data_type) ? 0.0 : 0
          func = lambda { |v|
            if v.is_a?(Array)
              v.empty? ? c : v.reduce(:+)
            else
              v
            end
          }

          reduction(child_context, tensor, func)
        when :reduce_prod
          c = fp_type?(tensor.data_type) ? 1.0 : 1
          func = lambda { |v|
            if v.is_a?(Array)
              v.empty? ? c : v.reduce(:*)
            else
              v
            end
          }

          reduction(child_context, tensor, func)
        when :transpose
          matrix_a = complete_eval(a, child_context)
          matrix_a.transpose
        when :eye
          rows = complete_eval(a, child_context)
          columns = complete_eval(b, child_context)

          Array.new(rows) do |i|
            Array.new(columns) do |col|
              if fp_type?(tensor.data_type)
                i == col ? 1.0 : 0.0
              else
                i == col ? 1 : 0
              end
            end
          end
        when :cond
          pred = complete_eval(tensor.options[:pred], child_context)

          if all_true?(pred)
            complete_eval(a, child_context)
          else
            complete_eval(b, child_context)
          end
        when :where
          pred = complete_eval(tensor.options[:pred], child_context)
          a = complete_eval(a, child_context)
          b = complete_eval(b, child_context)

          call_3way_vector_op(pred, a, b, child_context, ->(t, u, v) { t ? u : v })
        when :less
          a = complete_eval(a, child_context)
          b = complete_eval(b, child_context)

          call_vector_op(:greater, a, b, child_context, ->(t, u) { t < u })
        when :greater
          a = complete_eval(a, child_context)
          b = complete_eval(b, child_context)

          call_vector_op(:greater, a, b, child_context, ->(t, u) { t > u })
        when :greater_equal
          a = complete_eval(a, child_context)
          b = complete_eval(b, child_context)

          call_vector_op(:greater_equal, a, b, child_context, ->(t, u) { t >= u })
        when :less_equal
          a = complete_eval(a, child_context)
          b = complete_eval(b, child_context)

          call_vector_op(:less_equal, a, b, child_context, ->(t, u) { t <= u })
        when :zeros, :ones, :zeros_like, :ones_like

          shape = if %i[zeros_like ones_like].include?(tensor.operation)
                    a = complete_eval(a, child_context)
                    shape_eval(a)
                  else
                    complete_eval(a, child_context) || tensor.shape.shape
                  end

          func = if %i[zeros zeros_like].include?(tensor.operation)
                   -> { tensor.data_type == :int32 ? 0 : 0.0 }
                 else
                   -> { tensor.data_type == :int32 ? 1 : 1.0 }
                 end

          if shape.is_a?(Array) && shape.size.zero?
            func.call
          else
            shape = [shape.to_i] unless shape.is_a?(Array)
            generate_vector(shape, generator: func)
          end
        when :shape
          input = complete_eval(a, child_context)
          shape_eval(input, tensor.options[:out_type])
        when :matmul
          matrix_a = complete_eval(a, child_context)
          matrix_b = complete_eval(b, child_context)

          rank_a = get_rank(matrix_a)
          rank_b = get_rank(matrix_b)

          raise "#{a.name} rank must be greater than 1" if rank_a < 2
          raise "#{b.name} rank must be greater than 1" if rank_b < 2

          matrix_a = matrix_a.transpose if tensor.options[:transpose_a]
          matrix_b = matrix_b.transpose if tensor.options[:transpose_b]

          # handle matrix multiplication with constants like 1 or 0
          matrix_a = matmul_const_transform(matrix_a, matrix_b, tensor)
          matrix_b = matmul_const_transform(matrix_b, matrix_a, tensor)

          # check matrix dimensions
          raise "incompatible shape sizes for matrix multiplication (#{matrix_a[0].size} != #{matrix_b.size}) #{shape_eval(matrix_a)} vs #{shape_eval(matrix_b)}" if matrix_a[0].size != matrix_b.size

          (Matrix[*matrix_a] * Matrix[*matrix_b]).to_a
        when :gradients
          raise 'not implemented in evaluator' # see TensorStream.gradients instead.
        when :identity
          complete_eval(a, child_context)
        when :print
          a = complete_eval(a, child_context)
          b = complete_eval(b, child_context)
          puts "#{tensor.options.fetch(:message, '')} #{b}"
          a
        when :rank
          a = complete_eval(a, child_context)
          get_rank(a)
        when :div
          process_vector_math_op(a, b, child_context, ->(t, u) { t / u })
        when :reshape
          arr = complete_eval(a, child_context)
          new_shape = complete_eval(b, child_context)

          flat_arr = arr.flatten
          return flat_arr[0] if new_shape.size.zero? && flat_arr.size == 1

          new_shape = fix_inferred_elements(new_shape, flat_arr.size)

          reshape(flat_arr, new_shape)
        when :pad
          a = complete_eval(a, child_context)
          p = complete_eval(tensor.options[:paddings], child_context)

          arr_pad(a, p, tensor.data_type)
        when :max
          a = complete_eval(a, child_context)
          b = complete_eval(b, child_context)

          call_vector_op(:max, a, b, child_context, ->(t, u) { [t, u].max })
        else
          raise "unknown op #{tensor.operation}"
        end.tap do |result|
          if tensor.breakpoint
            a = complete_eval(a, child_context)
            b = complete_eval(b, child_context)

            tensor.breakpoint.call(tensor, a, b, complete_eval(result, child_context))
          end
          @context[tensor.name] = result
        end
      rescue EvaluatorExcecutionException => e
        raise e
      rescue StandardError => e
        # a = complete_eval(a, child_context)
        # b = complete_eval(b, child_context)
        # puts "name: #{tensor.given_name}"
        # puts "op: #{tensor.to_math(true, 1)}"
        # puts "A: #{a}" if a
        # puts "B: #{b}" if b
        # binding.pry
        puts e.backtrace.join("\n")
        raise EvaluatorExcecutionException.new(e, tensor), "error #{e.message} while evaluating #{tensor.name} : #{tensor.to_math} defined at #{tensor.source}"
      end

      def eval_tensor(tensor, child_context)
        return tensor unless tensor.is_a?(Tensor)
        return @context[tensor.name] if @context.key?(tensor.name)

        if tensor.value.is_a?(Array)
          tensor.value.collect do |item|
            item.is_a?(Tensor) ? run(item, child_context) : item
          end
        else
          tensor.value.is_a?(Tensor) ? run(tensor.value, child_context) : tensor.value
        end.tap do |result|
          @context[tensor.name] = result
        end
      end

      private

      def get_max_with_axis(a, target_axis, current_axis, output_type)
        if target_axis == current_axis
          if a[0].is_a?(Array)
            (0...a[0].size).each.collect do |column_index|
              max = nil
              max_index = 0
              a.each_with_index do |row, row_index|
                if max.nil? || row[column_index] > max
                  max = row[column_index]
                  max_index = row_index
                end
              end

              Tensor.cast_dtype(max_index, output_type)
            end
          else
            max = nil
            max_index = 0
            a.each_with_index do |x, index|
              if max.nil? || x > max
                max = x
                max_index = index
              end
            end
            Tensor.cast_dtype(max_index, output_type)
          end
        else
          a.collect do |row|
            get_max_with_axis(row, target_axis, current_axis + 1, output_type)
          end
        end
      end

      def reduction(child_context, tensor, func)
        val = complete_eval(tensor.items[0], child_context)
        axis = tensor.options[:axis]
        keep_dims = tensor.options[:keepdims]

        res = if axis.is_a?(Array)
                axis.each do |x|
                  val = reduce_axis(x, val, keep_dims, child_context, func)
                end

                func.call(val.flatten)
              else
                reduce_axis(axis, val, keep_dims, child_context, func)
              end
        res
      end

      def arr_pad(arr, paddings, data_type = :float32, rank = 0)
        raise "padding #{paddings[rank]} needs to have to elements [before, after]" if paddings[rank].size != 2

        before = paddings[rank][0]
        after = paddings[rank][1]
        pad_value = fp_type?(data_type) ? 0.0 : 0
        if arr[0].is_a?(Array)
          next_dim_elem = arr.collect { |a| arr_pad(a, paddings, data_type, rank + 1) }
          padding = deep_dup_array(next_dim_elem[0], pad_value)
          Array.new(before) { padding } + next_dim_elem + Array.new(after) { padding }
        else
          Array.new(before) { pad_value } + arr + Array.new(after) { pad_value }
        end
      end

      def deep_dup_array(arr, value = nil)
        if arr.is_a?(Array)
          arr.dup.collect do |a|
            deep_dup_array(a, value)
          end
        else
          value.nil? ? arr : value
        end
      end

      def slice_tensor(input, start, size)
        start_index = start.shift
        dimen_size = start_index + size.shift

        input[start_index...dimen_size].collect do |item|
          if item.is_a?(Array)
            slice_tensor(item, start.dup, size.dup)
          else
            item
          end
        end
      end

      def matmul_const_transform(mat, mat_b, tensor)
        if !mat.is_a?(Array)
          compat_shape = shape_eval(mat_b).reverse
          func = -> { tensor.data_type == :int32 ? mat.to_i : mat.to_f }

          generate_vector(compat_shape, generator: func)
        else
          mat
        end
      end

      def fix_inferred_elements(shape, total_size)
        return shape if shape.empty?

        current_size = shape.inject(1) { |product, n| n > 0 ? product * n : product }
        inferred_size = total_size / current_size
        shape.map { |s| s == -1 ? inferred_size : s }
      end

      def reshape(arr, new_shape)
        return arr if new_shape.empty?

        s = new_shape.shift

        if new_shape.size.zero?
          raise "reshape dimen mismatch #{arr.size} != #{s}" if arr.size != s
          return arr
        end

        dim = (arr.size / s)
        arr.each_slice(dim).collect do |slice|
          reshape(slice, new_shape.dup)
        end
      end

      def call_op(op, a, child_context, func)
        a = complete_eval(a, child_context)
        process_function_op(a, child_context, func)
      rescue FullEvalNotPossible
        TensorStream.send(op.to_sym, a)
      end

      def call_vector_op(op, a, b, child_context, func)
        process_vector_math_op(a, b, child_context, func)
      rescue FullEvalNotPossible
        TensorStream.send(op.to_sym, a, b)
      end

      def process_vector_math_op(a, b,  child_context, op)
        eval_a = complete_eval(a, child_context) unless a.nil?
        eval_b = complete_eval(b, child_context) unless b.nil?

        raise FullEvalNotPossible.new, "full eval not possible for #{a.name}" if eval_a.is_a?(Tensor) || eval_b.is_a?(Tensor)

        # ruby scalar
        if get_rank(eval_a).zero?
          if get_rank(eval_b).zero?
            op.call(eval_a, eval_b)
          else
            constant_op(eval_b, eval_a, child_context, op, true)
          end
        elsif get_rank(eval_a) > 0
          if get_rank(eval_b) > 0
            vector_op(eval_a, eval_b, child_context, op)
          else
            constant_op(eval_a, eval_b, child_context, op)
          end
        end
      end

      def get_rank(value, rank = 0)
        return rank unless value.is_a?(Array)
        return rank + 1 if value.empty?

        get_rank(value[0], rank + 1)
      end

      def concat_array(values, axis)
        combined_array = values.shift
        axis = get_rank(combined_array) - 1 if axis == -1

        values.each do |v|
          combined_array = concat(combined_array, v, axis)
        end
        combined_array
      end

      def concat(a, b, axis)
        if axis.zero?
          a + b
        else
          a.each_with_index.collect do |i, index|
            concat(i, b[index], axis - 1)
          end
        end
      end

      def process_function_op(a, child_context, op)
        # ruby scalar
        if (a.is_a?(Tensor) && a.shape.rank > 0) || a.is_a?(Array)
          constant_op(a, 0, child_context, op)
        elsif !a.is_a?(Tensor) || a.shape.rank.zero?
          v = run(a, child_context)
          raise FullEvalNotPossible.new, "full eval not possible for #{v.name}" if v.is_a?(Tensor) && !v.is_const

          op.call(v, 0)
        else
          raise 'cannot be here'
        end
      end

      def resolve_placeholder(placeholder, _execution_context = {})
        return nil if placeholder.nil?
        return placeholder if retain.include?(placeholder)

        var = if placeholder.is_a?(Placeholder)
                @context[placeholder.name.to_sym].tap do |c|
                  raise "missing placeholder #{placeholder.name}" if c.nil?
                end
              else
                placeholder
              end

        return var unless placeholder.is_a?(Tensor)
        Tensor.cast_dtype(var, placeholder.data_type)
      end

      def reduce_axis(axis, val, keep_dims, child_context, op = ->(v) { v.is_a?(Array) ? v.reduce(:+) : v })
        val = run(val, child_context)
        return val.is_a?(Array) ? op.call(val.flatten) : val if axis.nil?
        return val.transpose.collect { |v| keep_dims ? [op.call(v)] : op.call(v) } if axis.zero?
        return val.collect { |v| keep_dims ? [op.call(v)] : op.call(v) } if axis == 1

        raise "can't handle with axis > 1 :("
      end

      def constant_add(vector, constant)
        run(vector).collect do |item|
          if item.is_a?(Array)
            constant_add(item, constant)
          elsif item.respond_to?(:value)
            item.value + constant
          else
            item + constant
          end
        end
      end

      def constant_op(vector, constant, child_context, op = ->(a, b) { a + b }, switch = false)
        eval_vector = complete_eval(vector, child_context)
        constant = complete_eval(constant, child_context)

        raise FullEvalNotPossible.new, "full eval not possible for #{eval_vector.name}" if eval_vector.is_a?(Tensor) || constant.is_a?(Tensor)

        eval_vector.each_with_index.collect do |item, index|
          c = if constant.is_a?(Array)
              if index < constant.size
                constant[index]
              else
                raise "incompatible tensor shapes used during op" if constant.size != 1
                constant[0]
              end
            else
              constant
            end
          if item.is_a?(Array)
            constant_op(item, c, child_context, op, switch)
          elsif item.respond_to?(:value)
            switch ? op.call(c, item.value) : op.call(item.value, c)
          else
            switch ? op.call(c, item) : op.call(item, c)
          end
        end
      end

      def call_3way_vector_op(v_a, v_b, v_c, child_context, op = ->(a, b, c) { a + b + c })
        return op.call(v_a, v_b, v_c) unless v_a.is_a?(Array)

        v_a.each_with_index.collect do |v1, index|
          v2 = v_b[index]
          v3 = v_c[index]
          if v1.is_a?(Array)
            call_3way_vector_op(v1, v2, v3, child_context, op)
          else
            op.call(v1, v2, v3)
          end
        end
      end

      def vector_op(vector, vector2, child_context, op = ->(a, b) { a + b })
        v_a = run(vector, child_context)
        v_b = run(vector2, child_context)

        if get_rank(v_a) < get_rank(v_b) # upgrade rank of A
          duplicated = Array.new(v_b.size) do
            v_a
          end
          return vector_op(duplicated, v_b, child_context, op)
        end

        v_a.each_with_index.collect do |item, index|
          next vector_op(item, v_b, child_context, op) if item.is_a?(Array) && get_rank(v_a) > get_rank(v_b)

          z = index < v_b.size ? v_b[index] : v_b[0]

          if item.is_a?(Array)
            constant_op(item, z, child_context, op)
          else
            item.respond_to?(:value) ? op.call(item.value, z.value) : op.call(item, z)
          end
        end
      end

      def all_true?(arr)
        if arr.is_a?(Array)
          arr.each do |a|
            return false unless all_true?(a)
          end
          return true
        end

        !!arr
      end

      def vector_add(vector, vector2, child_context)
        v_a = run(vector, child_context)
        v_b = run(vector2, child_context)

        v_a.each_with_index.collect do |item, index|
          if item.is_a?(Array)
            constant_add(item, constant)
          elsif item.respond_to?(:value)
            item.value + v_b[index].value
          else
            item + v_b[index]
          end
        end
      end

      def generate_vector(shape, dtype: :float32, generator:)
        if shape.is_a?(Integer)
          Array.new(shape) do
            generator.call
          end
        elsif shape.size > 1
          Array.new(shape[0]) do
            generate_vector(shape[1..shape.size], generator: generator, dtype: dtype)
          end
        elsif shape.size == 1
          Array.new(shape[0]) do
            generator.call
          end
        elsif shape.size.zero?
          generator.call
        end
      end
    end
  end
end
