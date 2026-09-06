import java.util.ArrayList;
import java.util.List;

public class VehicleManager {
    private List<Vehicle> vehicles = new ArrayList<>();

    public void addVehicle(Vehicle vehicle) throws DuplicateVehicleException {
        if (vehicles.contains(vehicle)) // 리스트에 이미 그 vehicle이 있다면
        {
            throw new DuplicateVehicleException(vehicle.toString() + " already exists in the list.");
        }
        else{
            vehicles.add(vehicle);
        }

    }

    public Vehicle searchVehicle(String brand, String model) throws VehicleNotFoundException {
        for (Vehicle vehicle : vehicles) {// for문으로 list 순회하며 만족하는 객체를 체크
            if (vehicle.getBrand().equals(brand) && vehicle.getModel().equals(model)) { 
                //여기는 string 클래스의 equals() 메소드 적용
                return vehicle;
            }
        } //찾지 못할 경우 아래의 오류 생성 코드 실행
        throw new VehicleNotFoundException("This vehicle :("+ brand+","+ model+")doesn't exist.");
    }

    public void removeVehicle(Vehicle vehicle) throws VehicleNotFoundException {

        if (!vehicles.contains(vehicle))
        {
            throw new VehicleNotFoundException("this vehicle doesn’t exist! ");
        }
        else{
            vehicles.remove(vehicle);
        }

    }

    public void printAllVehicles()
    {
        if (vehicles.size() == 0)
        {
            System.out.println("there is no car! ");
        }
        else
        {
            for (Vehicle vehicle : vehicles)
            {
                System.out.println(vehicle);  // 이전에 작성한 toString() 메소드 사용하여 각 기체의 정보 출력
            }
        }

    }
}
