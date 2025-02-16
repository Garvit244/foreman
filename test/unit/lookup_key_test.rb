require 'test_helper'

class LookupKeyTest < ActiveSupport::TestCase
  def setup
    @host1, @host2, @host3 = FactoryGirl.create_list(:host, 3,
                               :location      => taxonomies(:location1),
                               :organization  => taxonomies(:organization1),
                               :puppetclasses => [puppetclasses(:one)],
                               :environment   => environments(:production))
  end

  def test_element_seperations
    key = ""
    as_admin do
      key = VariableLookupKey.create!(:key => "ntp", :path => "domain,hostgroup\n domain", :puppetclass => Puppetclass.first)
    end
    elements = key.send(:path_elements) # hack to access private method
    assert_equal "domain", elements[0][0]
    assert_equal "hostgroup", elements[0][1]
    assert_equal "domain", elements[1][0]
  end

  def test_path2match_single_domain_path
    key   = ""
    value = ""
    as_admin do
      key   = VariableLookupKey.create!(:key => "ntp", :path => "domain", :puppetclass => Puppetclass.first)
      value = LookupValue.create!(:value => "ntp.mydomain.net", :match => "domain =  mydomain.net", :lookup_key => key)
    end

    @host1.domain = domains(:mydomain)
    assert_equal [value.match], key.send(:path2matches,@host1)
  end

  def test_fetching_the_correct_value_to_a_given_key
    key   = ""
    value = ""
    puppetclass = puppetclasses(:one)

    as_admin do
      key   = PuppetclassLookupKey.create!(:key => "dns", :path => "domain\npuppetversion", :override=>true)
      value = LookupValue.create!(:value => "[1.2.3.4,2.3.4.5]", :match => "domain =  mydomain.net", :lookup_key => key)
      EnvironmentClass.create!(:puppetclass => puppetclass, :environment => environments(:production),
                               :puppetclass_lookup_key => key)
    end

    key.reload
    assert key.lookup_values_count > 0
    @host1.domain = domains(:mydomain)

    assert_equal value.value, Classification::ClassParam.new(:host => @host1).enc['base']['dns']
  end

  def test_path2match_single_hostgroup_path
    key   = ""
    value = ""
    as_admin do
      key   = VariableLookupKey.create!(:key => "ntp", :path => "hostgroup", :puppetclass => Puppetclass.first)
      value = LookupValue.create!(:value => "ntp.pool.org", :match => "hostgroup =  Common", :lookup_key => key)
    end
    @host1.hostgroup = hostgroups(:common)
    assert_equal [value.match], key.send(:path2matches,@host1)
  end

  def test_multiple_paths
    @host1.hostgroup = hostgroups(:common)
    @host1.environment = environments(:testing)

    @host2.hostgroup = hostgroups(:unusual)
    @host2.environment = environments(:testing)

    @host3.environment = environments(:testing)

    default = "default"
    key    = ""
    value1 = ""
    value2 = ""
    puppetclass = Puppetclass.first
    as_admin do
      key    = PuppetclassLookupKey.create!(:key => "dns", :path => "environment,hostgroup \n hostgroup", :default_value => default, :override=>true)
      value1 = LookupValue.create!(:value => "v1", :match => "environment=testing,hostgroup=Common", :lookup_key => key)
      value2 = LookupValue.create!(:value => "v2", :match => "hostgroup=Unusual", :lookup_key => key)

      LookupValue.create!(:value => "v22", :match => "fqdn=#{@host2.fqdn}", :lookup_key => key)
      EnvironmentClass.create!(:puppetclass => puppetclass, :environment => environments(:testing),
                               :puppetclass_lookup_key => key)
      HostClass.create!(:host => @host1,:puppetclass=>puppetclass)
      HostClass.create!(:host => @host2,:puppetclass=>puppetclass)
      HostClass.create!(:host => @host3,:puppetclass=>puppetclass)
    end

    key.reload

    assert_equal value1.value, Classification::ClassParam.new(:host=>@host1).enc['apache']['dns']
    assert_equal value2.value, Classification::ClassParam.new(:host=>@host2).enc['apache']['dns']
    assert_equal default, Classification::ClassParam.new(:host=>@host3).enc['apache']['dns']
    assert key.overridden?(@host2)
    refute key.overridden?(@host1)
  end

  def test_parameters_multiple_paths
    @host1.hostgroup = hostgroups(:common)
    @host2.hostgroup = hostgroups(:unusual)

    default = "default"
    key    = ""
    value1 = ""
    value2 = ""
    puppetclass = Puppetclass.first

    as_admin do
      key    = VariableLookupKey.create!(:key => "dns", :path => "environment,hostgroup \n hostgroup", :puppetclass => puppetclass,
                                 :default_value => default, :override=>true)
      value1 = LookupValue.create!(:value => "v1", :match => "hostgroup=Common", :lookup_key => key)
      value2 = LookupValue.create!(:value => "v2", :match => "hostgroup=Unusual", :lookup_key => key)

      @host1.puppetclasses << puppetclass
      @host2.puppetclasses << puppetclass
      @host3.puppetclasses << puppetclass
    end

    key.reload

    assert_equal value1.value, Classification::GlobalParam.new(:host=>@host1).enc['dns']
    assert_equal value2.value, Classification::GlobalParam.new(:host=>@host2).enc['dns']
    assert_equal default, Classification::GlobalParam.new(:host=>@host3).enc['dns']
  end

  def test_value_should_not_be_changed
    param = lookup_keys(:three)
    default = param.default_value
    param.save
    assert_equal default, param.default_value
    assert_equal default, param.default_value_before_type_cast
  end

  test "this is a smart variable?" do
    assert lookup_keys(:two).class == VariableLookupKey
  end

  test "this is a smart class parameter?" do
    assert_not_deprecated do
      assert lookup_keys(:complex).puppet?
    end
  end

  test "when changed, an audit entry should be added" do
    env = FactoryGirl.create(:environment)
    pc = FactoryGirl.create(:puppetclass, :with_parameters, :environments => [env])
    key = pc.class_params.first
    assert_difference('Audit.count') do
      key.override = true
      key.default_value = "new default value"
      key.save!
    end
    assert_equal pc.name, key.audits.last.associated_name
  end

  test "should create smart variable with the same name as class parameters" do
    env = FactoryGirl.create(:environment)
    pc = FactoryGirl.create(:puppetclass, :with_parameters, :environments => [env])
    key = pc.class_params.first
    smart_variable = VariableLookupKey.create!(:key => key.key, :path => "hostgroup", :puppetclass => Puppetclass.first)
    assert_valid smart_variable
  end

  test "should not create two smart variables with the same name" do
    VariableLookupKey.create!(:key => "smart-varialble", :path => "hostgroup", :puppetclass => Puppetclass.first, :default_value => "default")
    smart_variable2 = VariableLookupKey.new(:key => "smart-varialble", :path => "hostgroup", :puppetclass => Puppetclass.first, :default_value => "default2")
    refute_valid smart_variable2
  end

  test "should not be able to merge overrides for a string" do
    key = FactoryGirl.build(:puppetclass_lookup_key, :as_smart_class_param,
                            :override => true, :key_type => 'string', :merge_overrides => true,
                            :puppetclass => puppetclasses(:one))
    refute_valid key
    assert_equal key.errors[:merge_overrides].first, _("can only be set for array or hash")
  end

  test "should be able to merge overrides for a hash" do
    key = FactoryGirl.build(:puppetclass_lookup_key, :as_smart_class_param,
                            :override => true, :key_type => 'hash', :merge_overrides => true,
                            :default_value => {}, :puppetclass => puppetclasses(:one))
    assert_valid key
  end

  test "should be able to merge overrides with default_value for a hash" do
    key = FactoryGirl.build(:puppetclass_lookup_key, :as_smart_class_param,
                            :override => true, :key_type => 'hash', :merge_overrides => true, :merge_default => true,
                            :default_value => {}, :puppetclass => puppetclasses(:one))
    assert_valid key
  end

  test "should not be able to merge default when merge_override is false" do
    key = FactoryGirl.build(:puppetclass_lookup_key, :as_smart_class_param,
                            :override => true, :key_type => 'hash', :merge_overrides => false, :merge_default => true,
                            :default_value => {}, :puppetclass => puppetclasses(:one))
    refute_valid key
    assert_equal "can only be set when merge overrides is set", key.errors[:merge_default].first
  end

  test "should not be able to avoid duplicates for a hash" do
    key = FactoryGirl.build(:puppetclass_lookup_key, :as_smart_class_param,
                            :override => true, :key_type => 'hash', :merge_overrides => true, :avoid_duplicates => true,
                            :default_value => {}, :puppetclass => puppetclasses(:one))
    refute_valid key
    assert_equal key.errors[:avoid_duplicates].first, _("can only be set for arrays that have merge_overrides set to true")
  end

  test "should be able to merge overrides for a array" do
    key = FactoryGirl.build(:puppetclass_lookup_key, :as_smart_class_param,
                            :override => true, :key_type => 'array', :merge_overrides => true, :avoid_duplicates => true,
                            :default_value => [], :puppetclass => puppetclasses(:one))
    assert_valid key
  end

  test "should not be able to avoid duplicates when merge_override is false" do
    key = FactoryGirl.build(:puppetclass_lookup_key, :as_smart_class_param,
                            :override => true, :key_type => 'array', :merge_overrides => false, :avoid_duplicates => true,
                            :default_value => [], :puppetclass => puppetclasses(:one))
    refute_valid key
    assert_equal key.errors[:avoid_duplicates].first, _("can only be set for arrays that have merge_overrides set to true")
  end

  test "should detect erb" do
    key = FactoryGirl.build(:puppetclass_lookup_key)
    assert key.contains_erb?('<% object_id %>')
    assert key.contains_erb?('<%= object_id %>')
    assert key.contains_erb?('[<% object_id %>, <% self %>]')
    refute key.contains_erb?('[1,2,3]')
    refute key.contains_erb?('{a: "b"}')
    refute key.contains_erb?('plain value')
  end

  test "array key is valid even with string value containing erb" do
    key = FactoryGirl.build(:puppetclass_lookup_key, :as_smart_class_param,
                            :override => true, :key_type => 'array', :merge_overrides => true, :avoid_duplicates => true,
                            :default_value => '<%= [1,2,3] %>', :puppetclass => puppetclasses(:one))
    assert key.valid?
  end

  test "array key is invalid with string value without erb" do
    key = FactoryGirl.build(:puppetclass_lookup_key, :as_smart_class_param,
                            :override => true, :key_type => 'array', :merge_overrides => true, :avoid_duplicates => true,
                            :default_value => 'whatever', :puppetclass => puppetclasses(:one))
    refute key.valid?
    assert_include key.errors.keys, :default_value
  end

  context "when key is a boolean and default_value is a string" do
    def setup
      @key = FactoryGirl.create(:puppetclass_lookup_key, :as_smart_class_param,
                               :override => true, :key_type => 'boolean',
                               :default_value => 'whatever', :puppetclass => puppetclasses(:one), :use_puppet_default => true)
    end

    test "default_value is not validated if use_puppet_default is true" do
      assert @key.valid?
    end

    test "default_value is validated if use_puppet_default is false" do
      @key.use_puppet_default = false
      refute @key.valid?
    end
  end

  test "#overridden? works for unsaved hosts" do
    key = FactoryGirl.create(:puppetclass_lookup_key)
    host = FactoryGirl.build(:host)
    refute key.overridden?(host)

    host.lookup_values_attributes = {'0' => {'lookup_key_id' => key.id.to_s, '_destroy' => 'false'}}.with_indifferent_access
    assert_equal 1, host.lookup_values.size
    assert key.overridden?(host)
  end
end
